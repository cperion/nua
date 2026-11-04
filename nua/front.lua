-- nua.front: Nua as a host of the Lua Mua (design macro-layer.md §5, §6). Mua
-- (mua/) parses every source; Nua gives the forms only it understands their meaning:
-- typed lambdas and functions (native words), opened untyped lambdas (callbacks whose bodies
-- work on staged values), `struct` and `oneof` (native types), `export` and `call`. The code
-- generator G below turns those nodes into calls into nua.stage; it was nua.syntax's.

local application = require 'nua.application'
local M = {}

local function str(s) return ('%q'):format(s) end

-- code generation ---------------------------------------------------------------------------

local G = {}
G.__index = G

-- body kinds: 'word' (native semantics: staged control flow and return),
-- 'host' (a Lua function inside a typed body: plain control flow, staged
-- operators)
local function new_body(kind, parent)
    return { kind = kind, scopes = { {} }, region = 0, loops = {}, parent = parent }
end

function M.codegen(filename, start_line)
    return setmetatable({ out = {}, line = start_line or 0, filename = filename,
                          body = nil }, G)
end

function G:emit(s) self.out[#self.out + 1] = s end

-- keep generated code on the source lines it came from
function G:at(line)
    if line and line > self.line then
        self:emit(('\n'):rep(line - self.line))
        self.line = line
    end
end

function G:err(msg, line)
    error(('%s:%s: %s'):format(self.filename, tostring(line or self.line), msg), 0)
end

function G:push_scope() local b = self.body; b.scopes[#b.scopes + 1] = {} end
function G:pop_scope() local b = self.body; b.scopes[#b.scopes] = nil end

function G:declare(name, info)
    local b = self.body
    info.region = b.region
    local sc = b.scopes[#b.scopes]
    info.open_order = #(sc.__opens or {})
    sc[name] = info
end

function G:lookup(name)
    local b = self.body
    if not b then return nil end
    for i = #b.scopes, 1, -1 do
        local v = b.scopes[i][name]
        if v then return v, b end
    end
    local p = b.parent
    while p do
        for i = #p.scopes, 1, -1 do
            local v = p.scopes[i][name]
            if v then return v, p end
        end
        p = p.parent
    end
    return nil
end

local function str(s) return ('%q'):format(s) end

-- expressions --------------------------------------------------------------------------------

local CMP = { ['=='] = 'eq', ['~='] = 'ne', ['<'] = 'lt', ['<='] = 'le', ['>'] = 'gt', ['>='] = 'ge' }

function G:lexical_name(name)
    local v = self:lookup(name)
    if v and v.loop_slot then
        return '__S.inferred_state(' .. v.loop_slot .. ', ' .. name .. ')'
    end
    return name
end

function G:expr(e, tail_chain)
    -- The same non-executing word-application proof drives minimal formatting.
    -- Unknown callees and semantic group boundaries keep the ordinary chain path.
    if self.application_facts then e = self.application_facts.normal[e] or e end
    local k = e.k
    if k == 'name' then
        if e.name == '__S' or e.name == '__ENV' then self:err("'" .. e.name .. "' is reserved", e.line) end
        if #self:opens(e.name) > 0 then
            -- Only openings newer than the nearest lexical binding can hide it.
            return ('__S.oname(%s, %s, function() return %s end)'):format(self:open_list(e.name), str(e.name), self:lexical_name(e.name))
        end
        return self:lexical_name(e.name)
    elseif k == 'home' then
        local v = self:lookup('__home')
        if not v then self:err('context-required: `..` reads an unnamed opened home, and there is none here', e.line) end
        return '__home'
    elseif k == 'spread' then
        self:err('spread-context: `..e` belongs in an argument, return or initializer list', e.line)
    elseif k == 'num' then return e.text
    elseif k == 'str' then return e.text
    elseif k == 'nil' or k == 'true' or k == 'false' then return k
    elseif k == 'vararg' then
        self:err("spread-syntax: use '..' for Nua expansion or an anonymous home", e.line)
    elseif k == 'paren' then return '(' .. self:expr(e.e) .. ')'
    elseif k == 'field' then
        -- through __S.dot: a native value's fields never meet the evaluator's own keys
        return '__S.dot(' .. self:expr(e.obj) .. ', ' .. str(e.name) .. ')'
    elseif k == 'index' then return '__S.index(' .. self:expr(e.obj) .. ', ' .. self:expr(e.key) .. ')'
    elseif k == 'call' and (e.fn.k == 'call' or e.fn.k == 'method') then
        -- a saturating chain: f(a)(b) do ... end accumulates arguments until f is saturated
        local groups = {}
        local node = e
        while node.k == 'call' and (node.fn.k == 'call' or node.fn.k == 'method') do
            table.insert(groups, 1, '__S.args(' .. self:list(node.args) .. ')')
            node = node.fn
        end
        if node.k == 'method' then
            local code = ('__S.%s(%s, %s, __S.args(%s), %s)'):format(node.boundary and 'bmchain' or 'mchain',
                self:prefix(node.obj), str(node.name), self:list(node.args), table.concat(groups, ', '))
            return tail_chain and ('__S.ret(' .. code .. ')') or code
        end
        if node.fn.k == 'name' and not self:lookup(node.fn.name) and #self:opens() > 0 then
            -- Resolve the actual opened member or lexical fallback before
            -- applying the boundary; syntax cannot know the opened vocabulary.
            local code = ('__S.%s(%s, %s, function() return %s end, __S.args(%s), %s)'):format(
                node.boundary and 'bochain' or 'ochain', self:open_list(),
                str(node.fn.name), node.fn.name, self:list(node.args), table.concat(groups, ', '))
            return tail_chain and ('__S.ret(' .. code .. ')') or code
        end
        local head = self:prefix(node.fn)
        if node.boundary then head = '__S.boundary(' .. head .. ')' end
        return ('__S.%s(%s, __S.args(%s), %s)'):format(tail_chain and 'tail_chain' or 'chain',
            head, self:list(node.args), table.concat(groups, ', '))
    elseif k == 'call' then
        if e.fn.k == 'name' and not self:lookup(e.fn.name) and #self:opens() > 0 then
            -- a bare call inside an opened region: the receiver's member wins
            local args = self:list(e.args)
            return ('__S.%s(%s, %s, function() return %s end%s)'):format(
                e.boundary and 'bocall' or 'ocall', self:open_list(),
                str(e.fn.name), e.fn.name, args ~= '' and (', ' .. args) or '')
        end
        if e.boundary then return '__S.boundary(' .. self:prefix(e.fn) .. ')(' .. self:list(e.args) .. ')' end
        return self:prefix(e.fn) .. '(' .. self:list(e.args) .. ')'
    elseif k == 'method' then
        local args = self:list(e.args)
        return '__S.' .. (e.boundary and 'bmcall' or 'mcall') .. '(' .. self:expr(e.obj) .. ', ' .. str(e.name) .. (args ~= '' and (', ' .. args) or '') .. ')'
    elseif k == 'table' then
        local spread = false
        for _, it in ipairs(e.items) do if it.kind == 'spread' then spread = true end end
        if spread then
            -- keyed spread: T { ..p, x = 5 }
            local parts = {}
            for _, it in ipairs(e.items) do
                if it.kind == 'spread' then
                    parts[#parts + 1] = "{ 'spread', " .. self:expr(it.e) .. ' }'
                elseif it.kind == 'named' then
                    parts[#parts + 1] = "{ 'field', " .. str(it.name) .. ', ' .. self:expr(it.e) .. ' }'
                else
                    self:err('spread-context: a keyed spread admits only `name = value` items and spreads', e.line)
                end
            end
            return '__S.keyed({ ' .. table.concat(parts, ', ') .. ' })'
        end
        local parts, keys = {}, {}
        for _, it in ipairs(e.items) do
            if it.kind == 'named' then
                if keys[it.name] then self:err(("duplicate key '%s'"):format(it.name), e.line) end
                keys[it.name] = true
            end
        end
        for _, it in ipairs(e.items) do
            if it.kind == 'pos' then parts[#parts + 1] = self:expr(it.e)
            elseif it.kind == 'named' then parts[#parts + 1] = it.name .. ' = ' .. self:expr(it.e)
            else parts[#parts + 1] = '[' .. self:expr(it.key) .. '] = ' .. self:expr(it.e) end
        end
        return '{ ' .. table.concat(parts, ', ') .. ' }'
    elseif k == 'binop' then
        local op = e.op
        if CMP[op] then
            return '__S.' .. CMP[op] .. '(' .. self:expr(e.a) .. ', ' .. self:expr(e.b) .. ')'
        elseif op == 'and' or op == 'or' then
            local a = self:expr(e.a)
            self.body.region = self.body.region + 1
            local b = self:expr(e.b)
            self.body.region = self.body.region - 1
            return '__S.' .. op .. '_(' .. a .. ', function() return ' .. b .. ' end)'
        end
        return '(' .. self:expr(e.a) .. ' ' .. op .. ' ' .. self:expr(e.b) .. ')'
    elseif k == 'unop' then
        if e.op == 'not' then return '__S.not_(' .. self:expr(e.a) .. ')' end
        if e.op == '#' then return '__S.len(' .. self:expr(e.a) .. ')' end
        return '(- ' .. self:expr(e.a) .. ')'
    elseif k == 'lambda' then
        return self:lambda(e.fn)
    elseif k == 'struct' then
        return self:struct(e)
    end
    self:err('internal: unknown expression ' .. tostring(k))
end

-- an expression used as the prefix of a call or index needs brackets unless it
-- is already a name, call or index
function G:prefix(e)
    local s = self:expr(e)
    if e.k == 'name' or e.k == 'field' or e.k == 'index' or e.k == 'call' or e.k == 'method'
        or e.k == 'paren' then
        return s
    end
    return '(' .. s .. ')'
end

function G:list(es)
    local parts, spread = {}, false
    for i, e in ipairs(es) do
        if e.k == 'spread' then
            spread = true
            parts[i] = '__S.sp(' .. self:expr(e.e) .. ')'
        else
            parts[i] = self:expr(e)
        end
    end
    if spread then return '__S.expand(' .. table.concat(parts, ', ') .. ')' end
    return table.concat(parts, ', ')
end

local function has_spread(es)
    for _, e in ipairs(es) do if e.k == 'spread' then return true end end
    return false
end

function G:struct(e)
    local parts = {}
    for _, f in ipairs(e.fields) do
        parts[#parts + 1] = '{ ' .. str(f.name) .. ', ' .. self:expr(f.type) .. ' }'
    end
    return (e.sum and '__S.oneof(' or '__S.struct(') .. str(e.name or (e.sum and 'oneof' or 'S')) .. ', { '
        .. table.concat(parts, ', ') .. ' })'
end

-- a lambda: a native word when it declares a result type, else a host function
function G:lambda(fn, method_of)
    local names = {}
    for i, p in ipairs(fn.params) do names[i] = p.name end
    if fn.rest then names[#names + 1] = '...' end
    local loc = str(self.filename .. ':' .. tostring(fn.line or self.line))
    if fn.result then
        local ps = {}
        for i, p in ipairs(fn.params) do
            if p.type then
                ps[i] = '{ ' .. str(p.name) .. ', ' .. self:expr(p.type) .. ' }'
            else
                ps[i] = '{ ' .. str(p.name) .. ' }'          -- a compile-time parameter
            end
        end
        local spec_head = 'name = ' .. str(fn.name or 'word') .. ', loc = ' .. loc
            .. ', params = { ' .. table.concat(ps, ', ') .. ' }, result = ' .. self:expr(fn.result)
            .. (fn.rest and (', rest = ' .. str(fn.rest)) or '')
            .. ', body = function('
        local fparams = {}
        if method_of then fparams[1] = 'self' end
        for i, p in ipairs(fn.params) do fparams[#fparams + 1] = p.name end
        if fn.rest then fparams[#fparams + 1] = fn.rest end   -- the pack, built by S.word
        local head = spec_head .. table.concat(fparams, ', ') .. ') '
        local body = self:function_body(fn, 'word', method_of)
        local spec = '{ ' .. head .. body .. ' end }'
        if method_of then return spec end
        return '__S.word' .. spec
    end
    -- an untyped lambda is a callback
    local body = self:function_body(fn, 'callback')
    if fn.rest then body = 'local ' .. fn.rest .. ' = __S.pack({ ... }) ' .. body end
    return '__S.callback(' .. str(fn.name or 'callback') .. ', ' .. loc .. ', function('
        .. table.concat(names, ', ') .. ') ' .. body .. ' end)'
end

function G:function_body(fn, kind, method_of)
    local saved = self.body
    local saved_facts = self.application_facts
    self.application_facts = saved_facts or application.analyze({ k = 'lambda', fn = fn })
    self.body = new_body(kind, saved)
    if method_of then self:declare('self', { immutable = true, param = true }) end
    for _, p in ipairs(fn.params) do
        self:declare(p.name, { immutable = kind == 'word', param = true, context = p.opened })
    end
    if fn.rest then self:declare(fn.rest, { immutable = true, pack = true }) end
    local o = self.out
    self.out = {}
    for _, p in ipairs(fn.params) do
        if p.opened then self:open_context(p.name) end
    end
    if fn.expr then
        if kind ~= 'host' then
            self:emit(' __S.ret(' .. self:expr(fn.expr) .. ')')
        else
            self:emit(' return ' .. self:expr(fn.expr))
        end
    else
        self:block(fn.body)
        if fn.end_line then self:at(fn.end_line) end
    end
    local parts = table.concat(self.out)
    self.out = o
    self.body = saved
    self.application_facts = saved_facts
    return parts
end

-- opening ----------------------------------------------------------------------------------------

-- Opened contexts, innermost first. With a name, stop at its nearest
-- declaration and include only openings newer than that declaration.
-- Synthetic loop-state bindings transport values; they do not declare names.
function G:opens(name)
    local out = {}
    local b = self.body
    while b do
        for i = #b.scopes, 1, -1 do
            local sc = b.scopes[i]
            local binding = name and sc[name]
            if binding and binding.loop_binding then binding = nil end
            if sc.__opens then
                for k = #sc.__opens, (binding and binding.open_order or 0) + 1, -1 do
                    out[#out + 1] = sc.__opens[k]
                end
            end
            if binding then return out end
        end
        b = b.parent
    end
    return out
end

function G:open_list(name)
    return '{ ' .. table.concat(self:opens(name), ', ') .. ' }'
end

-- Retain the receiver independently of later bindings of its source name.
function G:open_context(var)
    self.open_id = (self.open_id or 0) + 1
    local alias = '__opened_' .. self.open_id
    self:emit((' local %s = __S.open(%s)'):format(alias, var))
    local sc = self.body.scopes[#self.body.scopes]
    sc.__opens = sc.__opens or {}
    table.insert(sc.__opens, alias)
end

-- statements ---------------------------------------------------------------------------------

function G:block(stats)
    self:push_scope()
    for _, s in ipairs(stats) do self:stat(s) end
    self:pop_scope()
end

function G:dead_check()
    if self.body.kind ~= 'host' then self:emit(' if __S.dead() then return end') end
end

-- a closure boundary for staged control flow
function G:closure(params, stats, extra)
    local o = self.out
    self.out = {}
    self.body.region = self.body.region + 1
    local nloops = #self.body.loops
    self:push_scope()
    if extra then extra() end
    for _, s in ipairs(stats) do self:stat(s) end
    self:pop_scope()
    for i = #self.body.loops, nloops + 1, -1 do self.body.loops[i] = nil end
    self.body.region = self.body.region - 1
    local text = table.concat(self.out)
    self.out = o
    return 'function(' .. params .. ') ' .. text .. ' end'
end

function G:assign_target(t, value, lexical)
    local function reject(message)
        -- A newer opening may supply the target; diagnose its lexical fallback
        -- only if specialization actually selects that fallback.
        if lexical then return 'error(' .. str(message) .. ')' end
        self:err(message, t.line)
    end
    if t.k == 'name' then
        local v, owner = self:lookup(t.name)
        if not lexical and #self:opens(t.name) > 0 then
            local fallback = self:assign_target(t, '__value', true)
            return ('__S.oset(%s, %s, %s, function(__value) %s end)'):format(
                self:open_list(t.name), str(t.name), value, fallback)
        end
        if v and v.inferred then
            local host
            if owner ~= self.body then
                host = 'error(' .. str("cannot assign '" .. t.name .. "': a typed body can only assign bindings it declares") .. ')'
            else
                host = t.name .. ' = __S.assign_name(' .. t.name .. ', __value, '
                    .. (self.body.region - v.region) .. ')'
            end
            return '__S.assign_inferred(' .. self:lexical_name(t.name) .. ', ' .. value
                .. ', function(__value) ' .. host .. ' end)'
        end
        if v and v.typed then
            -- a typed local is a place, also from a callback inside its word
            return '__S.set(' .. t.name .. ', ' .. value .. ')'
        end
        if not v or owner ~= self.body then
            return reject(("cannot assign '%s': a typed body can only assign bindings it declares"):format(t.name))
        end
        if v.context then
            return reject(("context-use: '%s' is an opened context; the whole context cannot be assigned"):format(t.name))
        end
        if v.pack then
            return reject(("pack-use: '%s' is a pack; it cannot be assigned"):format(t.name))
        end
        if v.loopvar then
            return reject(("'%s' is a loop variable; it cannot be assigned"):format(t.name))
        end
        if v.typed then
            return '__S.set(' .. t.name .. ', ' .. value .. ')'
        end
        if v.immutable then
            -- a parameter: assignment writes through it if it is a reference
            return '__S.assign_param(' .. t.name .. ', ' .. value .. ', ' .. str(t.name) .. ')'
        end
        -- an untyped binding: writes through a reference, otherwise rebinds
        local k = self.body.region - v.region
        return t.name .. ' = __S.assign_name(' .. t.name .. ', ' .. value .. ', ' .. k .. ')'
    elseif t.k == 'field' then
        return '__S.setindex(' .. self:prefix(t.obj) .. ', ' .. str(t.name) .. ', ' .. value .. ')'
    elseif t.k == 'index' then
        return '__S.setindex(' .. self:prefix(t.obj) .. ', ' .. self:expr(t.key) .. ', ' .. value .. ', true)'
    end
    self:err('cannot assign to this expression', t.line)
end

-- the typed locals of this body that a loop mentions: its explicit state
local function names_in(node, out)
    if type(node) ~= 'table' then return end
    if node.k == 'name' then out[node.name] = true end
    for k, v in pairs(node) do
        if type(v) == 'table' and k ~= 'type' then names_in(v, out) end
    end
end

function G:loop_state(nodes)
    local seen = {}
    for _, n in ipairs(nodes) do names_in(n, seen) end
    local list = {}
    for name in pairs(seen) do
        local v, owner = self:lookup(name)
        if v and (v.typed or v.inferred) and owner == self.body then list[#list + 1] = name end
    end
    table.sort(list)
    return list
end

function G:state_list(state)
    local q, values = {}, {}
    for i, n in ipairs(state) do
        q[i] = str(n)
        values[i] = '(' .. self:lexical_name(n) .. ' or false)'
    end
    return '{ ' .. table.concat(values, ', ') .. ' }, { ' .. table.concat(q, ', ') .. ' }'
end

function G:loop_bindings(state)
    local params, bindings = {}, {}
    for i, n in ipairs(state) do
        local v = self:lookup(n)
        if v.inferred then
            self.loop_id = (self.loop_id or 0) + 1
            params[i] = '__inferred_loop_' .. self.loop_id
            bindings[n] = { inferred = true, loop_slot = params[i], region = v.region, loop_binding = true }
        else
            params[i] = n
            bindings[n] = { typed = true, region = v.region, loop_binding = true }
        end
    end
    return table.concat(params, ', '), function()
        for n, v in pairs(bindings) do self.body.scopes[#self.body.scopes][n] = v end
    end
end

function G:cond(e)
    -- in a host function a condition is host truth; native Bool values decide
    -- only when known
    if self.body.kind == 'host' then return '__S.truth(' .. self:expr(e) .. ')' end
    return self:expr(e)
end

function G:stat(s)
    self:at(s.line)
    local k = s.k
    local word = self.body.kind ~= 'host'
    if k == 'open' then
        if s.init then
            -- bind once, then open; a place stays a place, so its fields are live
            self:emit(' local ' .. s.name .. ' = __S.open_bind(' .. self:expr(s.init) .. ')')
            self:declare(s.name, { immutable = true, context = true })
        end
        self:open_context(self:expr({ k = 'name', name = s.name }))
        return
    end
    if k == 'local' then
        local has_type = false
        for _, n in ipairs(s.names) do if n.type then has_type = true end end
        if has_type then
            if #s.exprs > #s.names then self:err('too many values in local declaration', s.line) end
            for i, n in ipairs(s.names) do
                if s.exprs[i] and s.exprs[i].k == 'spread' then
                    self:err('spread-context: a typed local takes one value; bind the spread to untyped locals', s.line)
                end
                local init = s.exprs[i] and self:expr(s.exprs[i]) or 'nil'
                if n.type then
                    self:emit(' local ' .. n.name .. ' = __S.decl(' .. self:expr(n.type) .. ', ' .. init
                        .. ', ' .. str(n.name) .. ')')
                    self:declare(n.name, { typed = true })
                else
                    self:emit(' local ' .. n.name .. ' = __S.infer(' .. init .. ', ' .. str(n.name) .. ')')
                    self:declare(n.name, { inferred = true })
                end
            end
            return
        end
        local names = {}
        for i, n in ipairs(s.names) do names[i] = n.name end
        if #s.exprs == 0 then
            self:emit(' local ' .. table.concat(names, ', '))
        elseif #s.names == 1 and #s.exprs == 1 and s.exprs[1].k ~= 'spread' then
            self:emit(' local ' .. names[1] .. ' = __S.infer(' .. self:expr(s.exprs[1]) .. ', ' .. str(names[1]) .. ')')
        else
            local quoted = {}
            for i, name in ipairs(names) do quoted[i] = str(name) end
            self:emit(' local ' .. table.concat(names, ', ') .. ' = __S.infern({ '
                .. table.concat(quoted, ', ') .. ' }, ' .. self:list(s.exprs) .. ')')
        end
        for _, n in ipairs(s.names) do self:declare(n.name, { inferred = true }) end
    elseif k == 'localfunction' then
        self:declare(s.name, {})
        local fn = s.fn
        self:emit(' local ' .. s.name .. '; ' .. s.name .. ' = ' .. self:lambda(fn))
    elseif k == 'assign' then
        local vals = {}
        if #s.targets == 1 then
            self:emit(' ' .. self:assign_target(s.targets[1], self:expr(s.exprs[1])))
            return
        end
        -- several targets: evaluate all values first, as Lua does
        local tmps = {}
        for i = 1, #s.targets do tmps[i] = '__a' .. i end
        self:emit(' do local ' .. table.concat(tmps, ', ') .. ' = ' .. self:list(s.exprs))
        for i, t in ipairs(s.targets) do
            self:emit(' ' .. self:assign_target(t, tmps[i]))
        end
        self:emit(' end')
    elseif k == 'callstat' then
        local text = self:expr(s.e)
        -- Lua 5.1 would read a leading '(' as a call of the previous line
        if text:sub(1, 1) == '(' then text = ';' .. text end
        self:emit(' ' .. text)
    elseif k == 'if' then
        if not word then
            for i, c in ipairs(s.clauses) do
                self:emit((i == 1 and ' if ' or ' elseif ') .. self:cond(c.cond) .. ' then')
                self:block(c.body)
            end
            if s.els then self:emit(' else'); self:block(s.els) end
            self:emit(' end')
            return
        end
        local function chain(i)
            local c = s.clauses[i]
            local cond = self:expr(c.cond)
            local tf = self:closure('', c.body)
            local ef
            if s.clauses[i + 1] then
                local o = self.out
                self.out = {}
                self.body.region = self.body.region + 1
                local inner = chain(i + 1)
                self.body.region = self.body.region - 1
                self.out = o
                ef = 'function() ' .. inner .. ' end'
            elseif s.els then
                ef = self:closure('', s.els)
            end
            return '__S.if_(' .. cond .. ', ' .. tf .. (ef and (', ' .. ef) or '') .. ')'
        end
        self:emit(' ' .. chain(1))
        self:dead_check()
    elseif k == 'while' then
        if not word then
            self:emit(' while ' .. self:cond(s.cond) .. ' do')
            self.body.loops[#self.body.loops + 1] = { region = self.body.region }
            self:block(s.body)
            self.body.loops[#self.body.loops] = nil
            self:emit(' end')
            return
        end
        -- the loop's state: typed locals it mentions become its parameters
        local state = self:loop_state({ s.cond, s.body })
        local params, bind_state = self:loop_bindings(state)
        self.body.region = self.body.region + 1
        self:push_scope()
        bind_state()
        local cond = self:expr(s.cond)
        self:pop_scope()
        self.body.region = self.body.region - 1
        local body = self:closure(params, s.body, function()
            bind_state()
            self.body.loops[#self.body.loops + 1] = { native = true, region = self.body.region }
        end)
        self:emit(' __S.while_(function(' .. params .. ') return ' .. cond .. ' end, ' .. body
            .. ', ' .. self:state_list(state) .. ')')
        self:dead_check()
    elseif k == 'numfor' then
        if s.type then
            if not word then
                self:err('a typed for loop is native; it belongs in a native word, not a host function', s.line)
            end
            local ty = self:expr(s.type)
            local lo, hi = self:expr(s.lo), self:expr(s.hi)
            local step = s.step and self:expr(s.step) or 'nil'
            local state = self:loop_state({ s.body })
            local state_params, bind_state = self:loop_bindings(state)
            local params = s.var .. (#state > 0 and (', ' .. state_params) or '')
            local body = self:closure(params, s.body, function()
                self:declare(s.var, { immutable = true, loopvar = true })
                bind_state()
                self.body.loops[#self.body.loops + 1] = { native = true, region = self.body.region }
            end)
            self:emit((' __S.for_(%s, %s, %s, %s, %s, %s)'):format(ty, lo, hi, step, body,
                self:state_list(state)))
            self:dead_check()
            return
        end
        -- a generation-time loop: plain Lua, bounds must be known
        local step = s.step and (', __S.num(' .. self:expr(s.step) .. ')') or ''
        self:emit((' for %s = __S.num(%s), __S.num(%s)%s do'):format(s.var, self:expr(s.lo),
            self:expr(s.hi), step))
        self:push_scope()
        self:declare(s.var, {})
        self.body.loops[#self.body.loops + 1] = { region = self.body.region }
        for _, st in ipairs(s.body) do self:stat(st) end
        self.body.loops[#self.body.loops] = nil
        self:pop_scope()
        self:emit(' end')
    elseif k == 'genfor' then
        self:emit(' for ' .. table.concat(s.names, ', ') .. ' in ' .. self:list(s.exprs) .. ' do')
        self:push_scope()
        for _, n in ipairs(s.names) do self:declare(n, {}) end
        self.body.loops[#self.body.loops + 1] = { region = self.body.region }
        for _, st in ipairs(s.body) do self:stat(st) end
        self.body.loops[#self.body.loops] = nil
        self:pop_scope()
        self:emit(' end')
    elseif k == 'repeat' then
        self:emit(' repeat')
        self:push_scope()
        self.body.loops[#self.body.loops + 1] = { region = self.body.region }
        for _, st in ipairs(s.body) do self:stat(st) end
        self.body.loops[#self.body.loops] = nil
        self:emit(' until __S.truth(' .. self:expr(s.cond) .. ')')
        self:pop_scope()
    elseif k == 'break' then
        local loop = self.body.loops[#self.body.loops]
        if not loop then self:err('break outside a loop', s.line) end
        if loop.native then
            self:emit(' do __S.loop_break() return end')
            return
        end
        if loop.region ~= self.body.region then
            self:err('break cannot leave a native branch; restructure the loop condition', s.line)
        end
        self:emit(' break')
    elseif k == 'continue' then
        local loop = self.body.loops[#self.body.loops]
        if not loop then self:err('continue outside a loop', s.line) end
        if not loop.native then
            self:err('continue is supported in native loops (typed for, while), not in generation-time loops', s.line)
        end
        self:emit(' do __S.loop_continue() return end')
    elseif k == 'do' then
        self:emit(' do')
        self:block(s.body)
        self:emit(' end')
    elseif k == 'return' then
        if #s.exprs > 1 and word and not has_spread(s.exprs) then
            self:err('a native word returns one value', s.line)
        end
        if word then
            local e = s.exprs[1]
            if e and self.application_facts then e = self.application_facts.normal[e] or e end
            if has_spread(s.exprs) then
                -- `return ..args`: the components, which must be exactly one value
                self:emit(' do __S.ret_one(' .. self:list(s.exprs) .. ') return end')
            elseif #s.exprs == 0 then
                self:emit(' do __S.ret() return end')
            elseif e.k == 'call' and e.fn.k ~= 'call' and e.fn.k ~= 'method' and not e.boundary
                and not (e.fn.k == 'name' and not self:lookup(e.fn.name) and #self:opens() > 0) then
                -- a tail call
                local args = self:list(e.args)
                self:emit(' do __S.tail(' .. self:prefix(e.fn) .. (args ~= '' and (', ' .. args) or '') .. ') return end')
            elseif e.k == 'call' and (e.fn.k == 'call' or e.fn.k == 'method') then
                self:emit(' do ' .. self:expr(e, true) .. ' return end')
            elseif e.k == 'method' and not e.boundary then
                local args = self:list(e.args)
                self:emit(' do local __o = ' .. self:prefix(e.obj) .. '; __S.tail(__o.' .. e.name .. ', __o'
                    .. (args ~= '' and (', ' .. args) or '') .. ') return end')
            else
                self:emit(' do __S.ret(' .. self:expr(e) .. ') return end')
            end
        else
            self:emit(' do return ' .. self:list(s.exprs) .. ' end')
        end
    elseif k == 'function' then
        self:err('a function statement cannot appear inside a typed body; use local function', s.line)
    elseif k == 'export' then
        self:err('export belongs at the top level', s.line)
    else
        self:err('internal: unknown statement ' .. tostring(k), s.line)
    end
end


-- the host ----------------------------------------------------------------------------------------

-- LuaJIT 3.0's forms the typed-body language does not stage yet (design macro-layer.md L3)
local NOT_STAGED = {
    compound = 'compound assignment', const = 'a const declaration', cond = 'the conditional `?:`',
    ['goto'] = 'goto', label = 'a label',
}
local NOT_STAGED_OPS = { ['??'] = '`??`', ['|'] = '`|`', ['&'] = '`&`', ['~'] = '`~`', ['<<'] = '`<<`',
                         ['>>'] = '`>>`', ['~>>'] = '`~>>`' }

-- prepare a typed body's nodes for G: contextual `with` is the call G knows (`with { ... }`,
-- the prelude's contextual constructor), and the forms G does not stage are rejected here
local function prepare(node, filename)
    local seen = {}
    local function reject(what, line)
        error(('%s:%s: %s is not available in a typed body yet; use it in Lua code around the word'):format(
            filename, tostring(line or '?'), what), 0)
    end
    local function walk(n)
        if type(n) ~= 'table' or seen[n] then return end
        seen[n] = true
        if n.k then
            if NOT_STAGED[n.k] then reject(NOT_STAGED[n.k], n.line) end
            if (n.k == 'binop' or n.k == 'unop') and NOT_STAGED_OPS[n.op] then reject('the operator ' .. NOT_STAGED_OPS[n.op], n.line) end
            if n.safe or n.safe_call then reject('safe navigation `?.`', n.line) end
            if n.k == 'lambda' and n.fn.arrow then reject('a short function `|x| -> e`', n.line) end
            if n.k == 'with' then
                n.k, n.fn, n.args = 'call', { k = 'name', name = 'with', line = n.line },
                    { { k = 'table', items = n.items, line = n.line } }
                n.items = nil
            end
        end
        for _, v in pairs(n) do walk(v) end
    end
    walk(node)
    return node
end

-- an opened untyped lambda: a parameter is opened (`do(..)`, `do(ctx..)`, a colon block)
local function opened(fn)
    for _, p in ipairs(fn.params) do if p.opened then return true end end
    return false
end

function M.host(filename)
    local host = { statements = {}, prefixes = {}, emit_statements = {} }
    -- `export name`, `export a.b`, `export name as "cname"`
    host.statements.export = function(p, tk)
        local r = p.r
        r:next()
        local name = r:name('after export').v
        local cname = name
        while r:accept('.') do
            local part = r:name('in export').v
            name, cname = name .. '.' .. part, cname .. '_' .. part
        end
        local nt = r:peek(1)
        if nt.t == 'name' and nt.v == 'as' and not nt.nl then
            r:next()
            local s = r:next()
            if s.t ~= 'string' then r:error('export ... as expects a string naming the C function', s) end
            cname = assert(loadstring('return ' .. s.v))()
        end
        return { k = 'export', name = name, cname = cname, line = tk.line }
    end
    host.emit_statements.export = function(s) return ('__S.export_word(%s, %q)'):format(s.name, s.cname) end
    -- `call f(x)`, `call m:put(k, v)` in a typed body: the application is a real call (a function
    -- boundary); elsewhere `call` is a name
    host.prefixes.call = function(p, tk)
        local nt = p.r:peek(2)
        if (p.typed_depth or 0) == 0 or nt.t ~= 'name' or nt.nl or nt.kw then return nil end
        p.r:next()
        local e = p:suffixed()
        if e.k ~= 'call' and e.k ~= 'method' then p.r:error('call needs an application: call f(x), call m:put(k, v)', tk) end
        local node = e
        while node.k == 'call' and (node.fn.k == 'call' or node.fn.k == 'method') do node = node.fn end
        node.boundary = true
        return e
    end
    host.typed_lambda = function(node)
        local g = M.codegen(filename, node.line)
        return g:lambda(prepare(node, filename).fn)
    end
    host.opened_lambda = function(node)
        local g = M.codegen(filename, node.line)
        return g:lambda(prepare(node, filename).fn)
    end
    host.typed_function = function(s)
        prepare(s, filename)
        if s.const then
            error(('%s:%s: a const typed function is not available yet; use local function'):format(filename, s.line), 0)
        end
        local g = M.codegen(filename, s.line)
        if s.k == 'localfunction' then
            -- the name is bound before the body: a recursive tail application sees it
            g.application_facts = application.analyze({ k = 'localfunction', name = s.name, fn = s.fn })
            return 'local ' .. s.name .. '; ' .. s.name .. ' = ' .. g:lambda(s.fn)
        end
        if s.method then
            return '__S.method(' .. table.concat(s.path, '.') .. ', ' .. str(s.method) .. ', ' .. g:lambda(s.fn, true) .. ')'
        end
        return table.concat(s.path, '.') .. ' = ' .. g:lambda(s.fn)
    end
    local function type_decl(node)
        prepare(node, filename)
        local g = M.codegen(filename, node.line)
        g.body = new_body('host')
        return g:struct(node)
    end
    host.struct, host.sum = type_decl, type_decl
    return host
end

M.opened = opened
return M
