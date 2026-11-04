-- dialect.parse: the Lua dialect's parser (design macro-layer.md §4.2; the surface rules are
-- syntax.md §2.4). One recursive-descent parser for whole files: Lua 5.1 with LuaJIT's
-- `goto`, labels and bitwise operators, and the dialect's forms: lambdas, juxtaposition, the
-- trailing colon, `=:`, `with` blocks, `endall`, `.name` entries, keyed spread, opening,
-- `continue`, and the typed forms (annotations, `Struct`, `Sum`). Its node shapes are those
-- of nua.syntax's parser, which it replaces.
--
--   parse(source, filename, host) -> block, tokens
--
-- `host` (optional) adds forms that only a host gives meaning to:
--   host.statements[name] = function(p, tk) -> node | nil   a statement keyword (`export`)
--   host.prefixes[name]   = function(p, tk) -> node | nil   an expression prefix (`call`)
-- A hook returning nil leaves the name to the ordinary grammar.
--
-- Nodes carry `line` (and `col` where a token starts them). Statements:
--   local{names={name,type,line}, exprs}  localfunction{name, fn}  function{path, method, fn}
--   assign{targets, exprs}  callstat{e}  if{clauses={cond,body}, els}  while{cond, body}
--   numfor{var, type, lo, hi, step, body}  genfor{names, exprs, body}  repeat{body, cond}
--   do{body}  return{exprs}  break  continue  goto{label}  label{name}  open{name, init}
--   compound{op, target, e} (`a += e`; op '+', '-', '*', '/', '%', '&', '|', '~', '<<', '>>',
--   '~>>', '..')  const{names, exprs}  localfunction{..., const = true}
-- Expressions:
--   name{name}  num{text}  str{text}  nil  true  false  vararg  home  spread{e}  paren{e}
--   field{obj, name}  index{obj, key}  call{fn, args, juxta?, boundary?}  method{obj, name, args}
--   lambda{fn}  table{items={kind=pos|named|keyed|spread, name, key, e}, with?}
--   with{items} (contextual)  binop{op, a, b, spelling?}  unop{op, a, spelling?}
--   cond{c, a, b} (`c ? a : b`)  struct{sum, fields={name,type}, name}
-- `field`, `index`, `call` and `method` carry `safe` for `?.`; a method `safe_call` for
-- `o:m?.(...)`. The customary operators are normalized: `!`, `&&`, `||`, `!=` arrive as
-- `not`, `and`, `or`, `~=` with their `spelling` kept (design macro-layer.md L3). A short
-- function `|a| -> e` is a lambda whose fn has `arrow`.
-- A function `fn` is { params={name,type,line,opened,unnamed}, vararg, rest, result, name,
-- line, end_line, body | expr, colon? }; it is typed when it has a `result`.

local lex = require 'dialect.lex'

local M = {}

-- the reader: significant tokens, each with the spacing and comments before it --------------

local Reader = {}
Reader.__index = Reader

function M.reader(tokens, filename)
    local sig, ws, nl = {}, {}, false
    for index, tk in ipairs(tokens) do
        if tk.t == 'space' or tk.t == 'comment' or tk.t == 'shebang' or tk.t == 'directive' then
            ws[#ws + 1] = tk.v
            if tk.v:find '[\r\n]' or tk.t == 'shebang' or tk.t == 'directive' then nl = true end
        else
            local s = { t = tk.t, v = tk.v, line = tk.line, col = tk.col, pos = tk.pos, index = index,
                        ws = table.concat(ws), nl = nl }
            if tk.t == 'keyword' then s.kw = tk.v end
            sig[#sig + 1] = s
            ws, nl = {}, false
        end
    end
    return setmetatable({ toks = sig, i = 1, filename = filename or '?' }, Reader)
end

function Reader:peek(n) return self.toks[self.i + (n or 1) - 1] or self.toks[#self.toks] end
function Reader:next()
    local tk = self:peek(1)
    if self.i < #self.toks then self.i = self.i + 1 end
    self.last_line = tk.line
    return tk
end
function Reader:is(v)
    local tk = self:peek(1)
    return tk.t == v or (tk.kw == v)
end
function Reader:accept(v) if self:is(v) then return self:next() end end
local function show(tk)
    if tk.t == 'eof' then return 'end of file' end
    return "'" .. tk.v .. "'"
end
function Reader:error(msg, tk)
    tk = tk or self:peek(1)
    error(('%s:%d:%d: %s'):format(self.filename, tk.line, tk.col, msg), 0)
end
function Reader:expect(v, what)
    if self:is(v) then return self:next() end
    self:error(("'%s' expected%s, got %s"):format(v, what and (' ' .. what) or '', show(self:peek(1))))
end
function Reader:name(what)
    local tk = self:peek(1)
    if tk.t ~= 'name' then self:error(('a name expected %s, got %s'):format(what or '', show(tk))) end
    return self:next()
end
-- a name token with this text
local function is_name(tk, v) return tk.t == 'name' and tk.v == v end

-- the parser --------------------------------------------------------------------------------

local P = {}
P.__index = P
M.Parser = P

-- LuaJIT's precedences (with its 3.0 syntax backport): left and right binding power. The
-- conditional `c ? a : b` is below all of them, right-associative (P:expr).
local BINARY = {
    ['or'] = { 1, 1 }, ['||'] = { 1, 1 }, ['??'] = { 1, 1 }, ['and'] = { 2, 2 }, ['&&'] = { 2, 2 },
    ['<'] = { 3, 3 }, ['>'] = { 3, 3 }, ['<='] = { 3, 3 }, ['>='] = { 3, 3 },
    ['~='] = { 3, 3 }, ['!='] = { 3, 3 }, ['=='] = { 3, 3 },
    ['|'] = { 4, 4 }, ['~'] = { 5, 5 }, ['&'] = { 6, 6 },
    ['<<'] = { 7, 7 }, ['>>'] = { 7, 7 }, ['~>>'] = { 7, 7 },
    ['..'] = { 9, 8 },
    ['+'] = { 10, 10 }, ['-'] = { 10, 10 },
    ['*'] = { 11, 11 }, ['/'] = { 11, 11 }, ['%'] = { 11, 11 },
    ['^'] = { 14, 13 },
}
local UNARY_PRIORITY = 12
M.BINARY = BINARY
-- the customary spellings and the classic operators they are (L3)
local ALIAS = { ['&&'] = 'and', ['||'] = 'or', ['!='] = '~=', ['!'] = 'not' }
local COMPOUND = { ['+='] = '+', ['-='] = '-', ['*='] = '*', ['/='] = '/', ['%='] = '%', ['&='] = '&',
                   ['|='] = '|', ['~='] = '~', ['<<='] = '<<', ['>>='] = '>>', ['~>>='] = '~>>', ['..='] = '..' }

local function binop_of(tk)
    if tk.kw == 'and' or tk.kw == 'or' then return tk.kw end
    if tk.t ~= 'name' and tk.t ~= 'string' and tk.t ~= 'number' and BINARY[tk.t] then return tk.t end
end

function M.parser(reader, host)
    return setmetatable({ r = reader, kinds = {}, host = host or {} }, P)
end

-- Context flags. A loop header's `do` ends it; inside brackets a colon is an annotation and
-- `with` entries do not apply; a `with` block's entries stop juxtaposition at the next entry.
function P:with_flags(flags, f)
    local saved = { in_header = self.in_header, in_bracket = self.in_bracket, in_with = self.in_with,
                    in_ternary = self.in_ternary }
    for k, v in pairs(flags) do self[k] = v end
    local a, b, c = f()
    for k, v in pairs(saved) do self[k] = v end
    return a, b, c
end
function P:header(f) return self:with_flags({ in_header = true }, f) end
function P:bracketed(f)
    return self:with_flags({ in_header = false, in_bracket = true, in_with = false, in_ternary = false }, f)
end
-- a body (a lambda's, a block's): none of the enclosing expression's contexts apply
function P:body(f)
    return self:with_flags({ in_header = false, in_bracket = false, in_with = false, in_ternary = false }, f)
end

-- blocks ------------------------------------------------------------------------------------

local BLOCK_END = { ['end'] = true, ['else'] = true, ['elseif'] = true, ['until'] = true }
local function is_endall(tk) return is_name(tk, 'endall') end
local function ends_block(tk) return tk.t == 'eof' or (tk.kw and BLOCK_END[tk.kw]) or is_endall(tk) end

function P:block(kind)
    self.kinds[#self.kinds + 1] = kind or 'other'
    local stats = self:body(function() return self:block_items() end)
    self.kinds[#self.kinds] = nil
    return stats
end

function P:block_items()
    local r = self.r
    local stats = {}
    while true do
        local tk = r:peek(1)
        if ends_block(tk) then break end
        if tk.kw == 'return' then
            stats[#stats + 1] = self:retstat()
            break
        end
        local s = self:statement()
        if s then stats[#stats + 1] = s end
    end
    return stats
end

function P:retstat()
    local r = self.r
    local tk = r:next()
    local exprs = {}
    local nt = r:peek(1)
    if not (ends_block(nt) or nt.t == ';') then exprs = self:exprlist() end
    while r:accept(';') do end                 -- semicolons anywhere (L1)
    return { k = 'return', exprs = exprs, line = tk.line }
end

-- `endall` closes every open dialect block (lambda or `with`) back to Lua control: each such
-- block ends there, and the outermost one consumes it
function P:close_dialect(what)
    local r = self.r
    local tk = r:peek(1)
    if is_endall(tk) then
        local enclosing = self.kinds[#self.kinds]
        if enclosing ~= 'lambda' and enclosing ~= 'with' then r:next() end
        return tk
    end
    return r:expect('end', 'to close ' .. what)
end

-- statements --------------------------------------------------------------------------------

-- the value after `=`: an expression, or `=:` a block lambda (`local f =: x`)
function P:assigned(hint)
    local r = self.r
    if r:is(':') then
        local c = r:next()
        return self:colon_lambda(c, hint)
    end
    return self:item(hint)
end
function P:assigned_list(hint)
    local list = { self:assigned(hint) }
    while self.r:accept(',') do list[#list + 1] = self:item() end
    return list
end

function P:statement()
    local r = self.r
    local tk = r:peek(1)
    local line = tk.line
    if tk.t == ';' then r:next() return nil end
    if tk.t == '::' then
        r:next()
        local n = r:name('in a label')
        r:expect('::', 'to close the label')
        return { k = 'label', name = n.v, line = line }
    end
    local kw = tk.kw
    if kw == 'local' then
        r:next()
        if r:is('function') then
            local ftk = r:next()
            local name = r:name('after local function').v
            local fn = self:funcbody(name, ftk)
            return { k = 'localfunction', name = name, fn = fn, line = line }
        end
        local first = r:name('in local declaration')
        if r:is('...') then r:error("spread-syntax: use '..' to open a binding") end
        if r:is('..') then
            -- `local ctx..` opens an existing binding; `local ctx.. = e` binds, then opens
            r:next()
            local init
            if r:accept('=') then init = self:assigned(first.v) end
            return { k = 'open', name = first.v, init = init, line = line }
        end
        local names, n = {}, first
        repeat
            if n == nil then n = r:name('in local declaration') end
            local ty
            if r:accept(':') then ty = self:typeexpr() end
            names[#names + 1] = { name = n.v, type = ty, line = n.line }
            n = nil
        until not r:accept(',')
        local exprs = {}
        if r:accept('=') then exprs = self:assigned_list(names[1].name) end
        return { k = 'local', names = names, exprs = exprs, line = line }
    elseif kw == 'if' then
        r:next()
        local clauses = {}
        local cond = self:expr()
        r:expect('then', 'after the if condition')
        clauses[1] = { cond = cond, body = self:block() }
        local els
        while true do
            if r:accept('elseif') then
                local c = self:expr()
                r:expect('then', 'after the elseif condition')
                clauses[#clauses + 1] = { cond = c, body = self:block() }
            elseif r:accept('else') then
                els = self:block()
                r:expect('end', 'to close if')
                break
            else
                r:expect('end', 'to close if')
                break
            end
        end
        return { k = 'if', clauses = clauses, els = els, line = line }
    elseif kw == 'while' then
        r:next()
        local cond = self:header(function() return self:expr() end)
        r:expect('do', 'after the while condition')
        local body = self:block()
        r:expect('end', 'to close while')
        return { k = 'while', cond = cond, body = body, line = line }
    elseif kw == 'for' then
        r:next()
        local n1 = r:name('after for')
        if r:is(':') or r:is('=') then
            local ty
            if r:accept(':') then ty = self:typeexpr() end
            r:expect('=', 'in a numeric for')
            local lo, hi, step = self:header(function()
                local lo = self:expr()
                r:expect(',', 'in a numeric for')
                local hi = self:expr()
                local step
                if r:accept(',') then step = self:expr() end
                return lo, hi, step
            end)
            r:expect('do', 'after the for range')
            local body = self:block()
            r:expect('end', 'to close for')
            return { k = 'numfor', var = n1.v, type = ty, lo = lo, hi = hi, step = step, body = body, line = line }
        end
        local names = { n1.v }
        while r:accept(',') do names[#names + 1] = r:name('in for').v end
        r:expect('in', 'in a generic for')
        local exprs = self:header(function() return self:exprlist() end)
        r:expect('do', 'after the for header')
        local body = self:block()
        r:expect('end', 'to close for')
        return { k = 'genfor', names = names, exprs = exprs, body = body, line = line }
    elseif kw == 'repeat' then
        r:next()
        local body = self:block()
        r:expect('until', 'to close repeat')
        local cond = self:expr()
        return { k = 'repeat', body = body, cond = cond, line = line }
    elseif kw == 'break' then
        r:next()
        return { k = 'break', line = line }
    elseif kw == 'goto' then
        r:next()
        return { k = 'goto', label = r:name('after goto').v, line = line }
    elseif kw == 'do' then
        -- where a statement starts, `do` is Lua's block
        r:next()
        local body = self:block()
        r:expect('end', 'to close do')
        return { k = 'do', body = body, line = line }
    elseif kw == 'function' then
        local ftk = r:next()
        local path = { r:name('after function').v }
        local method
        while true do
            if r:accept('.') then path[#path + 1] = r:name('in a function name').v
            elseif r:accept(':') then method = r:name('in a method name').v break
            else break end
        end
        local fn = self:funcbody(method or path[#path], ftk)
        return { k = 'function', path = path, method = method, fn = fn, line = line }
    elseif kw == 'return' then
        return self:retstat()
    end
    if tk.t == 'name' then
        local hook = self.host.statements and self.host.statements[tk.v]
        if hook then
            local node = hook(self, tk)
            if node then return node end
        end
        if tk.v == 'const' and not r:peek(2).nl
            and (r:peek(2).t == 'name' or r:peek(2).kw == 'function') then
            -- LuaJIT's const declaration, never a juxtaposed call (L2)
            r:next()
            if r:is('function') then
                local ftk = r:next()
                local name = r:name('after const function').v
                return { k = 'localfunction', name = name, fn = self:funcbody(name, ftk), const = true, line = line }
            end
            local names = {}
            repeat
                local n = r:name('in a const declaration')
                names[#names + 1] = { name = n.v, line = n.line }
            until not r:accept(',')
            local exprs = {}
            if r:accept('=') then exprs = self:assigned_list(names[1].name) end
            return { k = 'const', names = names, exprs = exprs, line = line }
        end
        if tk.v == 'continue' then
            -- `continue` is the statement unless it is used as a name: `continue(...)`,
            -- `continue = ...`, `continue.x`, `continue "s"`
            local nt = r:peek(2)
            if not (nt.t == '(' or nt.t == '=' or nt.t == '.' or nt.t == ':' or nt.t == '['
                or nt.t == 'string' or nt.t == '{' or nt.t == ',') then
                r:next()
                return { k = 'continue', line = line }
            end
        end
    end
    -- an expression statement: a call, an assignment or a compound assignment
    local e = self:suffixed(nil, nil, true)
    local op = COMPOUND[r:peek(1).t]
    if op then
        if e.k ~= 'name' and e.k ~= 'index' and e.k ~= 'field' then r:error('cannot assign to this expression', tk) end
        r:next()
        return { k = 'compound', op = op, target = e, e = self:expr(), line = line }
    end
    if r:is('=') or r:is(',') then
        local targets = { e }
        while r:accept(',') do targets[#targets + 1] = self:suffixed() end
        r:expect('=', 'in an assignment')
        for _, t in ipairs(targets) do
            if t.k ~= 'name' and t.k ~= 'index' and t.k ~= 'field' then r:error('cannot assign to this expression', tk) end
        end
        local exprs = self:assigned_list(targets[1].k == 'name' and targets[1].name or nil)
        return { k = 'assign', targets = targets, exprs = exprs, line = line }
    end
    -- a bare name or qualified name as a statement is a call with no arguments (§2.4 rule 10)
    if self:named(e) then e = self:implicit_call(e) end
    if e.k ~= 'call' and e.k ~= 'method' then
        r:error('syntax error: an expression statement must be a call or an assignment', tk)
    end
    return { k = 'callstat', e = e, line = line }
end

-- parameters and bodies ---------------------------------------------------------------------

-- `( params ) [: result] (= expr | block end)` after `function` or `do`
function P:funcbody(name, at, opts)
    local r = self.r
    opts = opts or {}
    local params, vararg, rest = {}, false, nil
    r:expect('(', 'to open the parameters')
    self:bracketed(function()
        if r:is(')') then return end
        repeat
            if rest then r:error('rest-position: the rest requirement ..' .. rest .. ' must be last', at) end
            if r:is('...') then
                if opts.lambda then r:error("spread-syntax: use '..' for opening or rest parameters", at) end
                r:next(); vararg = true
                if r:peek().t == 'name' or r:is(':') then
                    r:error("spread-syntax: use '..' for opening or rest parameters", at)
                end
            elseif r:is('..') then
                local dots = r:next()
                local nt = r:peek(1)
                if nt.t == 'name' then
                    rest = r:next().v                            -- `..args`: the rest requirement
                else
                    -- `..` or `..: T`: one unnamed home, opened
                    local ty
                    if r:accept(':') then ty = self:typeexpr() end
                    params[#params + 1] = { name = '__home', type = ty, opened = true, unnamed = true, line = dots.line }
                end
            else
                local n = r:name('in the parameters')
                local opened = false
                if r:is('...') then r:error("spread-syntax: use '..' to open a parameter", at) end
                if r:is('..') then r:next(); opened = true end   -- `ctx..`
                local ty
                if r:accept(':') then ty = self:typeexpr() end
                params[#params + 1] = { name = n.v, type = ty, line = n.line, opened = opened }
            end
        until not r:accept(',')
    end)
    r:expect(')', 'to close the parameters')
    local nopen = 0
    for _, p in ipairs(params) do if p.opened then nopen = nopen + 1 end end
    if nopen > 1 then r:error('one parameter may be opened', at) end
    local result
    if r:accept(':') then result = self:typeexpr() end
    if vararg and (result or opts.lambda) then
        r:error("spread-syntax: use '..' for opening or rest parameters", at)
    end
    for _, p in ipairs(params) do
        if p.type and not result then
            r:error(("parameter '%s' is typed, but %s declares no result type; a typed function "
                .. "declares it: (...): T"):format(p.unnamed and '..' or p.name, name or 'the lambda'), at)
        end
    end
    local fn = { params = params, vararg = vararg, rest = rest, result = result, name = name, line = at and at.line }
    if opts.allow_expr ~= false and r:accept('=') then
        fn.expr = self:body(function() return self:expr() end)
        fn.end_line = r.last_line
        return fn
    end
    if opts.expr_only then r:error("expected '=' after the handler's parameters", at) end
    -- a typed lambda is a word body: `endall` stops at it, as at Lua control (syntax.md §10.9)
    local dialect_block = opts.lambda and not result
    fn.body = self:block(dialect_block and 'lambda' or 'other')
    local e
    if dialect_block then e = self:close_dialect(name and ("'" .. name .. "'") or 'the lambda')
    else e = r:expect('end', 'to close ' .. (name and ("'" .. name .. "'") or 'the body')) end
    fn.end_line = e.line
    return fn
end

-- A colon block (§2.4 rule 11): after the colon, names (`x y`), an opened name (`ctx..`), `..`
-- or nothing, to the end of the line; then a block to `end`. Nothing or `..` opens what the
-- activity hands over (`do(..)`).
function P:colon_lambda(colon, hint)
    local r = self.r
    local params = {}
    local opened = false
    while not r:peek(1).nl and r:peek(1).t ~= 'eof' do
        local tk = r:peek(1)
        if tk.t == 'name' and not is_endall(tk) then
            r:next()
            local p = { name = tk.v, line = tk.line }
            if r:is('..') and not r:peek(1).nl then
                if opened then r:error('one parameter may be opened', tk) end
                r:next(); p.opened, opened = true, true
            end
            params[#params + 1] = p
        elseif tk.t == '..' then
            if opened or #params > 0 then r:error("'..' alone opens the unnamed home; it takes no other names", tk) end
            r:next()
            params[1] = { name = '__home', opened = true, unnamed = true, line = tk.line }
            opened = true
        else
            r:error(("a block colon is followed by parameter names and the end of the line, got %s"):format(show(tk)), tk)
        end
    end
    if #params == 0 then params[1] = { name = '__home', opened = true, unnamed = true, line = colon.line } end
    local body = self:block('lambda')
    local e = self:close_dialect(hint and ("'" .. hint .. "'") or 'the block')
    return { k = 'lambda', fn = { params = params, body = body, name = hint, line = colon.line, end_line = e.line,
                                  colon = true }, line = colon.line }
end

-- a type annotation is an ordinary expression; it ends where an expression must end
-- (`,` `)` `=` a keyword, or a new line before a name)
function P:typeexpr() return self:expr(nil, true) end

-- expressions -------------------------------------------------------------------------------

-- `..e` in an ordered supply (arguments, returns, initializers); `..` alone is the home
function P:item(hint)
    local r = self.r
    if r:is('..') then
        local nt = r:peek(2)
        if nt.t == ',' or nt.t == ')' or nt.t == 'eof' or nt.t == ']' or nt.t == '}'
            or (nt.kw and (BLOCK_END[nt.kw] or nt.kw == 'then' or nt.kw == 'do')) then
            return self:expr(hint)
        end
        local d = r:next()
        return { k = 'spread', e = self:expr(), line = d.line }
    end
    return self:expr(hint)
end

function P:exprlist(hint)
    local list = { self:item(hint) }
    while self.r:accept(',') do list[#list + 1] = self:item() end
    return list
end

-- an expression, with the conditional `c ? a : b` below every binary operator: the middle
-- operand takes no colon of its own (no method call, no block colon: LuaJIT's rule), the last
-- one may be another conditional (right-associative)
function P:expr(hint, in_type)
    local e = self:subexpr(0, hint, in_type)
    local r = self.r
    if not in_type and r:is('?') then
        local q = r:next()
        local a = self:with_flags({ in_ternary = true }, function() return self:subexpr(0) end)
        r:expect(':', "between the conditional's alternatives")
        local b = self:expr(hint)
        e = { k = 'cond', c = e, a = a, b = b, line = q.line }
    end
    return e
end

function P:subexpr(limit, hint, in_type)
    local r = self.r
    local tk = r:peek(1)
    local left
    if tk.kw == 'not' or tk.t == '!' or tk.t == '-' or tk.t == '#' or tk.t == '~' then
        r:next()
        local a = self:subexpr(UNARY_PRIORITY, nil, in_type)
        local op = tk.kw or tk.t
        left = { k = 'unop', op = ALIAS[op] or op, spelling = ALIAS[op] and op or nil, a = a, line = tk.line }
    else
        left = self:simple(hint, in_type)
    end
    while true do
        local nt = r:peek(1)
        local op = binop_of(nt)
        if not op or BINARY[op][1] <= limit then break end
        r:next()
        local right = self:subexpr(BINARY[op][2], nil, in_type)
        left = { k = 'binop', op = ALIAS[op] or op, spelling = ALIAS[op] and op or nil, a = left, b = right, line = nt.line }
    end
    return left
end

-- does the token after `with` begin an entry (`name =`, `name =:`, `.name`, `[`, `..`, a
-- literal)? Then `with` opens a block (§2.4 rule 12); otherwise it is a name.
function P:entry_ahead(k)
    local r = self.r
    local tk = r:peek(k)
    local nt = r:peek(k + 1)
    if tk.t == 'name' then
        if nt.t == '(' then return self:handler_ahead(k) end         -- `done() = ...`
        return nt.t == '=' or (nt.t == ':' and nt.ws ~= '')
    end
    if tk.t == '.' then return nt.t == 'name' and nt.ws == '' end
    return tk.t == '[' or tk.t == '..' or tk.t == 'number' or tk.t == 'string' or tk.kw == 'true' or tk.kw == 'false'
end

-- after an operand, `with` opens a block unless `=` follows or it touches `.` or `(`
-- (`t.with`, `with(x)` are names)
function P:with_block_ahead()
    local nt = self.r:peek(2)
    if nt.t == '=' or nt.t == 'eof' then return false end
    if (nt.t == '.' or nt.t == '(') and nt.ws == '' then return false end
    return true
end

function P:simple(hint, in_type)
    local r = self.r
    local tk = r:peek(1)
    if tk.t == 'number' then r:next() return self:postfix_literal({ k = 'num', text = tk.v, line = tk.line }) end
    if tk.t == 'string' then r:next() return self:postfix_literal({ k = 'str', text = tk.v, line = tk.line }) end
    if tk.kw == 'nil' then r:next() return { k = 'nil', line = tk.line } end
    if tk.kw == 'true' then r:next() return { k = 'true', line = tk.line } end
    if tk.kw == 'false' then r:next() return { k = 'false', line = tk.line } end
    if tk.t == '..' then r:next() return { k = 'home', line = tk.line } end
    if tk.t == '...' then r:next() return { k = 'vararg', line = tk.line } end
    if tk.t == '{' then return self:table() end
    if tk.kw == 'function' then
        local ftk = r:next()
        return { k = 'lambda', fn = self:funcbody(hint, ftk, { allow_expr = false }), line = tk.line }
    end
    if tk.kw == 'do' then return self:lambda(hint) end
    if tk.t == '|' or tk.t == '||' or (tk.t == 'name' and r:peek(2).t == '->') then
        return self:short_function(hint)
    end
    -- contextual `with`: where an expression starts, before an entry
    if is_name(tk, 'with') and not in_type and self:entry_ahead(2) then
        r:next()
        return { k = 'with', items = self:with_entries(tk), line = tk.line }
    end
    return self:suffixed(hint, in_type)
end

-- LuaJIT's short function: `|a, b| -> e`, `x -> e`, `|| -> e`, `|...| -> e`, and the block
-- form `|x| -> do ... end`; the expression body is a whole expression
function P:short_function(hint)
    local r = self.r
    local tk = r:next()
    local params, vararg = {}, false
    if tk.t == '|' then
        if not r:is('|') then
            repeat
                if r:is('...') then r:next(); vararg = true; break end
                local n = r:name('in a short function')
                params[#params + 1] = { name = n.v, line = n.line }
            until not r:accept(',')
        end
        r:expect('|', "to close the short function's parameters")
    elseif tk.t == 'name' then
        params[1] = { name = tk.v, line = tk.line }
    end
    r:expect('->', "after the short function's parameters")
    local fn = { params = params, vararg = vararg, name = hint, line = tk.line, arrow = true }
    if r:is('do') then
        r:next()
        fn.body = self:block('lambda')
        fn.end_line = self:close_dialect('the short function').line
    else
        fn.expr = self:body(function() return self:expr() end)
        fn.end_line = r.last_line
    end
    return { k = 'lambda', fn = fn, line = tk.line }
end

-- a literal followed by a postfix chain: ("x"):rep(3)
function P:postfix_literal(e)
    local nt = self.r:peek(1)
    if nt.t == '.' and self.in_with and nt.nl then return e end      -- the next `with` entry
    if nt.t == '.' or nt.t == ':' or nt.t == '[' then
        return self:suffixed_from({ k = 'paren', e = e, line = e.line }, 'literal', true)
    end
    return e
end

-- `do` lambdas: `do(params) = expr`, `do(params) ... end`, `do ... end`
function P:lambda(hint)
    local r = self.r
    local dtk = r:next()
    if r:is('(') then
        return { k = 'lambda', fn = self:funcbody(hint, dtk, { lambda = true }), line = dtk.line }
    end
    local body = self:block('lambda')
    local e = self:close_dialect('the lambda')
    return { k = 'lambda', fn = { params = {}, body = body, name = hint, line = dtk.line, end_line = e.line },
             line = dtk.line }
end

-- after `name (`: does a balanced parameter list end in `=` or `:`?
function P:handler_ahead(k)
    local r = self.r
    local depth, i = 0, (k or 1) + 1
    while true do
        local tk = r:peek(i)
        if tk.t == 'eof' then return false end
        if tk.t == '(' then depth = depth + 1
        elseif tk.t == ')' then
            depth = depth - 1
            if depth == 0 then
                local nt = r:peek(i + 1)
                return nt.t == '=' or nt.t == ':'
            end
        end
        i = i + 1
    end
end

-- one entry of a table constructor or a `with` block
function P:entry()
    local r = self.r
    local tk = r:peek(1)
    if tk.t == '..' then
        r:next()
        return { kind = 'spread', e = self:expr(), line = tk.line }
    elseif tk.t == '[' then
        r:next()
        local key = self:bracketed(function() return self:expr() end)
        r:expect(']')
        r:expect('=')
        return { kind = 'keyed', key = key, e = self:assigned(), line = tk.line }
    elseif tk.t == '.' and r:peek(2).t == 'name' and r:peek(2).ws == '' then
        -- `.name` is `name = name`
        r:next()
        local n = r:next()
        return { kind = 'named', name = n.v, e = { k = 'name', name = n.v, line = n.line }, short = true, line = n.line }
    elseif tk.t == 'name' and r:peek(2).t == '=' then
        r:next(); r:next()
        return { kind = 'named', name = tk.v, e = self:assigned(tk.v), line = tk.line }
    elseif tk.t == 'name' and r:peek(2).t == '(' and self:handler_ahead() then
        -- `name(params) = body` is `name = do(params) = body`
        r:next()
        local fn = self:funcbody(tk.v, tk, { expr_only = true })
        return { kind = 'named', name = tk.v, e = { k = 'lambda', fn = fn, line = tk.line }, line = tk.line }
    end
    return { kind = 'pos', e = self:expr(), line = tk.line }
end

function P:table()
    local r = self.r
    local open = r:expect('{')
    local items = self:bracketed(function()
        local items = {}
        while not r:is('}') do
            items[#items + 1] = self:entry()
            if not (r:accept(',') or r:accept(';')) then break end
        end
        return items
    end)
    r:expect('}', 'to close the table')
    return { k = 'table', items = items, line = open.line }
end

-- `with` entries to `end` (§2.4 rule 12): commas optional; an entry ends where the next one
-- begins (a name followed by `=` or `=:`, or a name or `.name` on a line of its own)
function P:with_entries(wtk)
    local r = self.r
    self.kinds[#self.kinds + 1] = 'with'
    local items = self:with_flags({ in_header = false, in_bracket = false, in_with = true }, function()
        local items = {}
        while not (r:is('end') or is_endall(r:peek(1)) or r:peek(1).t == 'eof') do
            items[#items + 1] = self:entry()
            while r:accept(',') or r:accept(';') do end
        end
        return items
    end)
    self.kinds[#self.kinds] = nil
    if r:peek(1).t == 'eof' then r:error('a `with` block is not closed (expected `end`)', wtk) end
    self:close_dialect('the `with` block')
    return items
end

-- `Struct { name: Type, ... }`, `Sum { ... }`, and their `with` forms
function P:struct(hint)
    local r = self.r
    local s = r:next()
    local kind = s.v
    local what = kind == 'Sum' and 'alternative' or 'field'
    local fields = {}
    local function field()
        local n = r:name('as a ' .. what)
        r:expect(':', ("after %s '%s' (%ss are declared name: Type)"):format(what, n.v, what))
        local ty = self:typeexpr()
        fields[#fields + 1] = { name = n.v, type = ty, line = n.line }
    end
    if r:accept('{') then
        self:bracketed(function()
            while not r:is('}') do
                field()
                if not (r:accept(',') or r:accept(';')) then break end
            end
        end)
        r:expect('}', 'to close the ' .. kind)
    else
        local wtk = r:next()                       -- `with`
        self.kinds[#self.kinds + 1] = 'with'
        self:with_flags({ in_header = false, in_bracket = false, in_with = true }, function()
            while not (r:is('end') or is_endall(r:peek(1)) or r:peek(1).t == 'eof') do
                field()
                while r:accept(',') or r:accept(';') do end
            end
        end)
        self.kinds[#self.kinds] = nil
        if r:peek(1).t == 'eof' then r:error('a `with` block is not closed (expected `end`)', wtk) end
        self:close_dialect('the ' .. kind)
    end
    return { k = 'struct', sum = kind == 'Sum', fields = fields, name = hint, line = s.line }
end

function P:primary(hint, in_type)
    local r = self.r
    local tk = r:peek(1)
    if tk.t == 'name' then
        if (tk.v == 'Struct' or tk.v == 'Sum')
            and (r:peek(2).t == '{' or (is_name(r:peek(2), 'with') and r:peek(3).t == 'name')) then
            return self:struct(hint), 'struct'
        end
        r:next()
        return { k = 'name', name = tk.v, line = tk.line, col = tk.col }, 'name'
    end
    if tk.t == '(' then
        r:next()
        local e = self:bracketed(function() return self:expr() end)
        r:expect(')', 'to close the parenthesis')
        return { k = 'paren', e = e, line = tk.line }, 'paren'
    end
    r:error('unexpected ' .. show(tk))
end

-- only names and qualified names are invoked by a bare statement (§2.4 rule 10)
function P:named(e) return e.k == 'name' or (e.k == 'field' and self:named(e.obj)) end
function P:implicit_call(e)
    if e.k == 'method' then return e end
    return { k = 'call', fn = e, args = {}, line = e.line, implicit = true }
end

function P:suffixed(hint, in_type, statement_head)
    local r = self.r
    local tk = r:peek(1)
    if tk.t == 'name' and not in_type then
        local hook = self.host.prefixes and self.host.prefixes[tk.v]
        if hook then
            local node = hook(self, tk)
            if node then return node end
        end
    end
    local e, kind = self:primary(hint, in_type)
    return self:suffixed_from(e, kind, false, in_type, statement_head)
end

-- can the next token start a juxtaposed argument after an expression that ended with `last`
-- ('name', 'call', 'index', 'arg', 'literal', ...)? (§2.4 rules 1 and 2)
function P:starts_argument(last)
    local r = self.r
    local tk = r:peek(1)
    if tk.t == 'number' or tk.t == 'string' then return true end
    if tk.kw == 'true' or tk.kw == 'false' then return true end
    if tk.kw == 'do' then return not self.in_header end
    if tk.t == 'name' and not is_endall(tk) then
        -- a name argument: only directly after a name or an argument, on the same line, and
        -- not the start of the next `with` entry
        if self.in_with then
            local nt = r:peek(2)
            if nt.t == '=' or (nt.t == ':' and nt.ws ~= '') then return false end
        end
        if tk.v == 'with' and (last == 'name' or last == 'arg' or last == 'call' or last == 'index' or last == 'paren') then
            return false
        end
        return (last == 'name' or last == 'arg') and not tk.nl
    end
    return false
end

-- an argument: a primary with its postfix chain, without further juxtaposition (§2.4 rule 3)
function P:argument()
    local r = self.r
    local tk = r:peek(1)
    if tk.kw == 'do' then return self:lambda() end
    if tk.t == 'name' and r:peek(2).t == '->' then return self:short_function() end   -- L2
    if tk.t == 'number' or tk.t == 'string' then
        r:next()
        local lit = { k = tk.t == 'number' and 'num' or 'str', text = tk.v, line = tk.line }
        return self:suffixed_from({ k = 'paren', e = lit, line = tk.line, literal = true }, 'literal', true, nil, nil, true)
    end
    if tk.kw == 'true' or tk.kw == 'false' then
        r:next()
        return self:suffixed_from({ k = tk.kw, line = tk.line }, 'literal', true, nil, nil, true)
    end
    local e, kind = self:primary()
    return self:suffixed_from(e, kind, true, nil, nil, true)
end

function P:args()
    local r = self.r
    local tk = r:peek(1)
    if tk.t == 'string' then r:next() return { { k = 'str', text = tk.v, line = tk.line } } end
    if tk.t == '{' then return { self:table() } end
    r:expect('(')
    local args = {}
    if not r:is(')') then args = self:bracketed(function() return self:exprlist() end) end
    r:expect(')', 'to close the arguments')
    return args
end

-- is the `:` ahead a block colon (§2.4 rule 11)? Not inside brackets or a type, and not a
-- method call (a name directly after the colon); the rest of its line is names and `..`
function P:block_colon_ahead(in_type)
    if in_type or self.in_bracket or self.in_with then return false end
    local r = self.r
    local nt = r:peek(2)
    if nt.t == 'name' and nt.ws == '' and not nt.nl then return false end   -- `xs:each`
    local k = 2
    while true do
        local tk = r:peek(k)
        if tk.nl or tk.t == 'eof' then return true end
        if not (tk.t == 'name' or tk.t == '..') then return false end
        k = k + 1
    end
end

-- `argument` marks a juxtaposed argument's own postfix chain: a spaced `(` ends it, so
-- `f a (b + 1)` is f(a)(b + 1) while `f a(b)` is f(a(b))
function P:suffixed_from(e, last, no_juxta, in_type, statement_head, argument)
    local r = self.r
    while true do
        local tk = r:peek(1)
        if tk.t == '.' then
            -- in a `with` block, `.name` on a line of its own begins the next entry
            if self.in_with and tk.nl then break end
            r:next()
            local n = r:name('after .')
            e = { k = 'field', obj = e, name = n.v, line = n.line }
            last = 'name'
        elseif tk.t == '[' then
            r:next()
            local key = self:bracketed(function() return self:expr() end)
            r:expect(']')
            e = { k = 'index', obj = e, key = key, line = tk.line }
            last = 'index'
        elseif tk.t == '?.' then
            -- safe navigation: `?.name`, `?.[k]`, `?.(...)`, `?."s"`, `?.{...}`, `?.:m(...)`
            r:next()
            local nt = r:peek(1)
            if nt.t == 'name' then
                r:next()
                e = { k = 'field', obj = e, name = nt.v, safe = true, line = nt.line }
                last = 'name'
            elseif nt.t == '[' then
                r:next()
                local key = self:bracketed(function() return self:expr() end)
                r:expect(']')
                e = { k = 'index', obj = e, key = key, safe = true, line = nt.line }
                last = 'index'
            elseif nt.t == '(' or nt.t == 'string' or nt.t == '{' then
                e = { k = 'call', fn = e, args = self:args(), safe = true, line = nt.line }
                last = 'call'
            elseif nt.t == ':' then
                r:next()
                local m = r:name('after ?.:')
                local args = self:args()
                e = { k = 'method', obj = e, name = m.v, args = args, safe = true, line = m.line }
                last = 'call'
            else
                r:error("a name, '[', '(', a string, '{' or ':' expected after '?.'")
            end
        elseif tk.t == ':' then
            if in_type or self.in_ternary then break end
            if self:block_colon_ahead(in_type) then
                -- the block belongs to the enclosing application, not to an argument's chain
                if no_juxta then break end
                local c = r:next()
                e = { k = 'call', fn = e, args = { self:colon_lambda(c) }, line = c.line, juxta = true }
                last = 'arg'
                goto continue
            end
            local nt = r:peek(2)
            if nt.t ~= 'name' then break end
            r:next(); r:next()
            local args
            local at = r:peek(1)
            local safe_call
            if at.t == '?.' and (r:peek(2).t == '(' or r:peek(2).t == 'string' or r:peek(2).t == '{') then
                r:next()                               -- `o:m?.(...)`
                safe_call, at = true, r:peek(1)
            end
            if safe_call then
                args = self:args()
            elseif at.t == ':' and not no_juxta and self:block_colon_ahead(in_type) then
                -- `words:each: k v`: the method's argument is a block
                local c = r:next()
                e = { k = 'method', obj = e, name = nt.v, args = { self:colon_lambda(c) }, line = nt.line }
                last = 'arg'
                goto continue
            elseif at.t == '(' or at.t == '{' then
                args = self:args()
            elseif is_name(at, 'with') and self:with_block_ahead() then
                local w = r:next()
                args = { { k = 'table', items = self:with_entries(w), with = true, line = w.line } }
            elseif self:starts_argument('name') then
                args = { (self:argument()) }
            elseif statement_head and self:named(e) then
                return self:implicit_call { k = 'method', obj = e, name = nt.v, args = {}, line = nt.line }
            else
                r:error(("method call '%s' needs arguments"):format(nt.v))
            end
            e = { k = 'method', obj = e, name = nt.v, args = args, safe_call = safe_call, line = nt.line }
            last = 'call'
        elseif tk.t == '(' and tk.nl then
            break                              -- `(` can begin a statement: a newline ends the expression
        elseif tk.t == '(' and argument and tk.ws ~= '' then
            break                              -- a spaced `(` starts the next argument group
        elseif tk.t == '(' then
            e = { k = 'call', fn = e, args = self:args(), line = tk.line }
            -- a spaced group is an argument, so names go on applying: `f (g x) y`
            last = tk.ws ~= '' and 'arg' or 'call'
        elseif tk.t == '{' and last ~= 'literal' then
            e = { k = 'call', fn = e, args = { self:table() }, line = tk.line }
            last = 'call'
        elseif tk.t == 'string' and last ~= 'literal' and no_juxta then
            -- inside an argument, a name's chain takes a string as Lua does: `f a "x"` is f(a("x"))
            r:next()
            e = { k = 'call', fn = e, args = { { k = 'str', text = tk.v, line = tk.line } }, line = tk.line }
            last = 'call'
        elseif is_name(tk, 'with') and last ~= 'literal' and self:with_block_ahead() then
            -- `T with ... end` is `T { ... }`
            local w = r:next()
            e = { k = 'call', fn = e, args = { { k = 'table', items = self:with_entries(w), with = true, line = w.line } },
                  line = w.line }
            last = 'call'
            if argument then break end
        elseif not no_juxta and self:starts_argument(last) then
            local a, ended = self:argument()
            e = { k = 'call', fn = e, args = { a }, line = tk.line, juxta = true }
            -- a name does not continue the application after an argument that ends with an
            -- attached call or a table (`f a(b) x` is f(a(b)) then x; §2.4 rules 1 and 8)
            last = ended == 'call' and 'call' or 'arg'
        else
            break
        end
        ::continue::
    end
    return e, last
end

-- the whole file --------------------------------------------------------------------------

function M.parse(source, filename, host)
    local tokens = lex.scan(source, filename)
    local r = M.reader(tokens, filename)
    local p = M.parser(r, host)
    local block = p:block('top')
    local tk = r:peek(1)
    if tk.t ~= 'eof' then
        if is_endall(tk) then r:error("'endall' closes no open lambda or `with` block here", tk) end
        r:error(("unexpected %s"):format(show(tk)), tk)
    end
    return block, tokens
end

return M
