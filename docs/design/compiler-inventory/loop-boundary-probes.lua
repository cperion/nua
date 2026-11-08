-- Observational companion to derivation.md; not replacement acceptance tests.
-- Run: luajit docs/design/compiler-inventory/loop-boundary-probes.lua
-- Four tiny sources stage with no_c. No preparation, runtime attachment,
-- C emission, compiler subprocess or gccjit invocation.
package.path = './?.lua;./.local/share/lua/5.1/?.lua;' .. package.path
package.loaded['nua.driver_loaded'] = true
local nua = dofile('nua.lua')
local S = require 'nua.stage'
local G = require 'nua.cgen'
local Builder = S.Builder

local counting = [[
local Counting = struct { count: U32, step: U32 }
function Counting:hit(): Unit
    self.count = self.count + self.step
end
]]
local function nested(restore)
    return counting .. [[
local entry = do(n: U32, m: U32): U32
    local state = Counting { count = 0, step = 3 }
    local alias = Ref state
    local i = U32 0
    while i < n do
        local j = U32 0
        while j < m do
            alias:hit
            j = j + 1
        end
]] .. (restore and '        state.count = 0\n' or '') .. [[
        i = i + 1
    end
    return state.count + state.step
end
export entry
]]
end
local function read_alias(known)
    return counting .. [[
local sample = do(n: U32): U32
    local state = Counting { count = 0, step = 3 }
    local alias = Ref state
    local total = U32 0
    for i: U32 = 1, n do
        state.count = state.count + 1
        total = total + alias.count
    end
    return total
end
]] .. (known and 'local entry = do(): U32 = sample 1\n'
    or 'local entry = do(n: U32): U32 = sample n\n') .. 'export entry\n'
end
local cases = {
    { 'nested_keep', nested(false) },
    { 'nested_restore', nested(true) },
    { 'read_alias_known', read_alias(true), reads = true },
    { 'read_alias_dynamic', read_alias(false), reads = true },
}
local function contents(v)
    if not S.is_value(v) then return 'host' end
    if v.k == 'known' then return 'K:' .. tostring(v.v) end
    if v.k == 'agg' then
        local fields = {}
        for _, f in ipairs(v.T.fields) do fields[#fields + 1] = f.name .. '=' .. contents(v.f[f.name]) end
        return '{' .. table.concat(fields, ',') .. '}'
    end
    return v.k
end
local function header(frame)
    local fields = {}
    for i, value in ipairs(frame.args) do
        fields[#fields + 1] = frame.desc.params[i].name .. '=' .. contents(value)
    end
    return table.concat(fields, ' ')
end
local function root_kind(place)
    local root = place
    while rawget(root, 'parent') do root = root.parent end
    return rawget(root, 'round_of') and 'round-copy' or 'original'
end
local original = { run_loop = Builder.run_loop, read = Builder.read, store = Builder.store }
local case, completions
Builder.run_loop = function(builder, frame)
    local description = header(frame)
    local result = original.run_loop(builder, frame)
    completions[#completions + 1] = description
    -- A containing construction can still discard this completed child.
    print('  loop completed (tentative): ' .. description)
    return result
end
Builder.read = function(builder, place)
    local value = original.read(builder, place)
    if case.reads and rawget(place, 'fname') == 'count' then
        print('  read ' .. root_kind(place) .. ' ' .. place.name .. ' -> ' .. contents(value))
    end
    return value
end
Builder.store = function(builder, place, value)
    if case.reads and rawget(place, 'fname') == 'count' then
        print('  store requested ' .. root_kind(place) .. ' ' .. place.name .. ' <- ' .. contents(value))
    end
    return original.store(builder, place, value)
end
local policy = S.call_policy
S.call_policy = 'written'
local ok, failure = pcall(function()
    for _, item in ipairs(cases) do
        case, completions = item, {}
        print('\nCASE ' .. case[1])
        local emitted, module = nua.compile(case[2], 'probe_' .. case[1] .. '.nua', { no_c = true })
        assert(emitted == nil, 'probe must not emit C')
        local returns = {}
        for _, fn in ipairs(module.functions) do
            G.walk_block(fn.body, function(statement)
                if statement.op == 'ret' and statement.e then
                    local e = statement.e
                    returns[#returns + 1] = e.op == 'const' and ('constant:' .. tostring(e.v)) or e.op
                end
            end)
        end
        print('  SUMMARY completed_loops=' .. #completions .. ' residual_returns=[' .. table.concat(returns, ',') .. ']')
    end
end)
for name, method in pairs(original) do Builder[name] = method end
S.call_policy = policy
if not ok then error(failure, 0) end
print('\nObserved four staging-only cases; no native-result or replacement-equivalence claim.')
