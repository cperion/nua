--[==[
macro.nua: the staged Lua -> C language as LuaMacro macros, on top of macro.let.

    do(x: U32): U32 = x + 1         a native word (it declares a result type)
    function T:m(n: U32): Unit ...  a method: a native word attached to struct T
    local function f(...): T ...    a recursive native word
    Struct { x: F32, y: F32 }       a struct type (annotations live only here,
                                    in parameter lists, typed locals and typed for)
    export name                     materialize a word as an exported C function

Typed bodies are parsed by nua.syntax, which turns comparisons, `and`/`or`,
conditions, typed assignment, loops and `return` into staged operations.
]==]

local M = require 'macro'
local lexer = require 'macro.lexer'
-- The trailing colon is a token rewrite, so it goes below macro.let's lexer
-- rules: a `do` it writes is applied like one the source wrote.
assert(not package.loaded['macro.let'], 'macro.nua must be loaded before macro.let')
local colon = require 'nua.colon'
local base_scan = lexer.scan_lua_tokenlist
function lexer.scan_lua_tokenlist(input) return colon.rewrite(base_scan(input)) end
require 'macro.let'
local TokenList = require 'macro.TokenList'
local syntax = require 'nua.syntax'

local function line_of() return lexer.line end

-- raw generated text, followed by the tokens the parser read ahead
local function result(text, leftovers)
    local put = TokenList.new { { 'string', text } }
    for _, tk in ipairs(leftovers) do put[#put + 1] = tk end
    return put
end

-- pad generated text to the number of source lines it replaces
local function pad(text, reader, start_line)
    local consumed = (reader.cur_line or start_line) - start_line
    local _, have = text:gsub('\n', '')
    if consumed > have then text = text .. ('\n'):rep(consumed - have) end
    return text
end

-- the significant token before the macro name, and the offset before it
local function before(get, k)
    local t, v = get:peek(k, true)
    while t == 'space' or t == 'comment' do
        k = k - 1
        t, v = get:peek(k, true)
    end
    return t, v, k
end

-- a typed lambda: macro.let read `do(` params `)` and the ':' of the result
M.let_typed = function (get, ptoks, info)
    local prefix = {}
    for i, tk in ipairs(ptoks) do prefix[i] = tk end
    prefix[#prefix + 1] = { ')', ')' }
    prefix[#prefix + 1] = { ':', ':' }
    local reader = syntax.reader(function () return get() end, prefix, line_of, M.filename, info.line)
    local text, left = syntax.translate_lambda(reader, info.name, info.line)
    if info.argument then text = text .. ')' end
    return result(pad(text, reader, info.line), left)
end

-- Untyped opened blocks use the same lexical resolver as nested callbacks.
-- The standalone Let macros retain their host-environment implementation.
M.let_opened = function (get, prefix, info)
    local reader = syntax.reader(function () return get() end, prefix, line_of, M.filename, info.line)
    local text, left = syntax.translate_lambda(reader, info.name, info.line, true)
    if info.argument then text = text .. ')' end
    return result(pad(text, reader, info.line), left)
end

M.define('__typed_function', function (get)
    local start = lexer.line
    local t, v = before(get, -3)
    local is_local = t == 'keyword' and v == 'local'
    local reader = syntax.reader(function () return get() end, {}, line_of, M.filename, start)
    local text, left = syntax.translate_function(reader, is_local, start)
    return result(pad(text, reader, start), left)
end)

-- `t.struct`, `t:export(...)`: a field or method name, not the macro
local function member_name(get)
    local t = before(get, -3)
    return t == '.' or t == ':'
end

local function type_macro(kind)
    return function (get)
        if member_name(get) then return nil, true end
        local start = lexer.line
        local name
        local t, v, k = before(get, -3)
        if t == '=' then
            local t2, v2 = before(get, k - 1)
            if t2 == 'iden' then name = v2 end
        end
        local reader = syntax.reader(function () return get() end, { { 'iden', kind } }, line_of,
            M.filename, start)
        local text, left = syntax.translate_struct(reader, name, start)
        return result(pad(text, reader, start), left)
    end
end

M.define('Struct', type_macro('Struct'))
M.define('Sum', type_macro('Sum'))

-- `export name` or `export name as "cname"`
M.define('export', function (get)
    if member_name(get) then return nil, true end
    local start = lexer.line
    local reader = syntax.reader(function () return get() end, {}, line_of, M.filename, start)
    local name = reader:name('after export').v
    local cname = name
    while reader:accept('.') do
        local part = reader:name('in export').v
        name = name .. '.' .. part
        cname = cname .. '_' .. part
    end
    local tk = reader:peek(1)
    if tk.t == 'iden' and tk.v == 'as' and not tk.nl then
        reader:next()
        local s = reader:next()
        if s.t ~= 'string' then reader:error('export ... as expects a string naming the C function', s) end
        cname = assert(loadstring('return ' .. s.v))()
    end
    local text = ('__S.export_word(%s, %q)'):format(name, cname)
    return result(pad(text, reader, start), reader:leftovers())
end)

-- `.name` in a table constructor is `name = name`. A `.` never follows `{`, `,`
-- or `;` in valid Lua, so no existing program changes. It is rewritten in the
-- token list, so typed bodies, macros and plain Lua code around them all see
-- the long form. Source tools (nua fmt) read the raw tokens and keep `.name`.
local ENTRY_START = { ['{'] = true, [','] = true, [';'] = true }
local ENTRY_END = { [','] = true, [';'] = true, ['}'] = true }

local function significant_before(tokens, i)
    i = i - 1
    while i >= 1 and (tokens[i][1] == 'space' or tokens[i][1] == 'comment') do i = i - 1 end
    return i >= 1 and tokens[i][1] or nil
end

local function significant_after(tokens, i)
    i = i + 1
    while tokens[i] and (tokens[i][1] == 'space' or tokens[i][1] == 'comment') do i = i + 1 end
    return tokens[i] and tokens[i][1] or nil
end

-- Keyed spread in any table constructor, `{ ..base, name = value }` (syntax §10.7): `..` never
-- starts a table entry in valid Lua. The table becomes `__nua_keyed{ [__nua_spread(1)] = base,
-- name = value }`, the same in plain Lua and in typed bodies; __nua_keyed applies the spread
-- rules, to a record constructor's fields or to a compile-time table.
local OPENERS, CLOSERS = { ['{'] = true, ['('] = true, ['['] = true }, { ['}'] = true, [')'] = true, [']'] = true }
local function spread_tables(tokens)
    local close_of, spreads, stack, named = {}, {}, {}, {}
    for i, tk in ipairs(tokens) do
        local t = tk[1]
        if t == 'iden' and stack[#stack] and tokens[stack[#stack]][1] == '{'
            and ENTRY_START[significant_before(tokens, i)] and significant_after(tokens, i) == '=' then
            local open = stack[#stack]
            named[open] = named[open] or {}
            table.insert(named[open], tk)
        end
        if OPENERS[t] then
            stack[#stack + 1] = i
        elseif CLOSERS[t] then
            local open = table.remove(stack)
            if open then close_of[open] = i end
        elseif t == '.' and tokens[i + 1] and tokens[i + 1][1] == '.'
            and not (tokens[i + 2] and tokens[i + 2][1] == '.') then   -- `...` is varargs
            local open = stack[#stack]
            local before = significant_before(tokens, i)
            if open and tokens[open][1] == '{' and ENTRY_START[before] then
                spreads[open] = spreads[open] or {}
                table.insert(spreads[open], i)
            end
        end
    end
    if not next(spreads) then return tokens end
    local before, after, replace = {}, {}, {}
    for open, list in pairs(spreads) do
        -- a duplicated field would vanish in the Lua table the spread is collected in
        local seen = {}
        for _, tk in ipairs(named[open] or {}) do
            if seen[tk[2]] then error(("line %d: duplicate field '%s'"):format(tk[3], tk[2]), 0) end
            seen[tk[2]] = true
        end
        local line = tokens[open][3]
        before[open] = { { '(', '(', line }, { 'iden', '__nua_keyed', line } }
        after[close_of[open]] = { { ')', ')', line } }
        for k, at in ipairs(list) do
            local l = tokens[at][3]
            replace[at] = { { '[', '[', l }, { 'iden', '__nua_spread', l }, { '(', '(', l },
                            { 'number', tostring(k), l }, { ')', ')', l }, { ']', ']', l },
                            { 'space', ' ', l }, { '=', '=', l }, { 'space', ' ', l } }
        end
    end
    local out, i = {}, 1
    while i <= #tokens do
        for _, t in ipairs(before[i] or {}) do out[#out + 1] = t end
        if replace[i] then
            for _, t in ipairs(replace[i]) do out[#out + 1] = t end
            i = i + 2
        else
            out[#out + 1] = tokens[i]
            for _, t in ipairs(after[i] or {}) do out[#out + 1] = t end
            i = i + 1
        end
    end
    return out
end

local scan_lua_tokenlist = lexer.scan_lua_tokenlist
function lexer.scan_lua_tokenlist(input)
    local tokens = spread_tables(scan_lua_tokenlist(input))
    local out, i = {}, 1
    while i <= #tokens do
        local tk, nx = tokens[i], tokens[i + 1]
        if tk[1] == '.' and nx and nx[1] == 'iden'
            and ENTRY_START[significant_before(tokens, i)]
            and ENTRY_END[significant_after(tokens, i + 1)] then
            local line = tk[3]
            out[#out + 1] = { 'iden', nx[2], line }
            out[#out + 1] = { 'space', ' ', line }
            out[#out + 1] = { '=', '=', line }
            out[#out + 1] = { 'space', ' ', line }
            out[#out + 1] = { 'iden', nx[2], line }
            i = i + 2
        else
            out[#out + 1] = tk
            i = i + 1
        end
    end
    return out
end

return M
