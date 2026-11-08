-- Observations of the existing evaluator, not replacement acceptance tests.
-- Run from the repository root: luajit docs/design/compiler-inventory/evaluation-trace.lua
-- Ten small sources use no_c: no preparation, runtime attachment, C emission,
-- compiler subprocess or gccjit invocation. Temporary method wrappers are restored.
-- Counts describe construction attempts, not necessarily source-body executions.
package.path = './?.lua;./.local/share/lua/5.1/?.lua;' .. package.path
package.loaded['nua.driver_loaded'] = true
local nua = dofile('nua.lua')
local S = require 'nua.stage'
local G = require 'nua.cgen'
local Builder = S.Builder

local count_down = [[
local function count_down(k: U32, x: U32): U32
    if x == 0 then return k end
    return count_down (k + 1) (x - 1)
end
]]
local counting = [[
local Counting = struct { count: U32, step: U32 }
function Counting:hit(): Unit
    self.count = self.count + self.step
end
]]
local cases = {
    { 'known_rounds', count_down .. [[
local entry = do(): U32 = count_down 0 3
export entry
]] },
    { 'mode_only', [[
local function descend(x: U32): U32
    if x == 0 then return x end
    return descend (x - 1)
end
local entry = do(x: U32): U32 = descend x
export entry
]] },
    { 'known_counter', count_down .. [[
local entry = do(x: U32): U32 = count_down 0 x
export entry
]] },
    { 'known_prefix', [[
local function walk(k: U32, x: U32): U32
    if k < 2 then return walk (k + 1) x end
    if x == 0 then return k end
    return walk (k + 1) (x - 1)
end
local entry = do(x: U32): U32 = walk 0 x
export entry
]] },
    { 'shared_recursion', [[
local function recurse(x: U32): U32
    if x == 0 then return U32 1 end
    return recurse(x - 1) + 1
end
local entry = do(x: U32): U32 = recurse x
export entry
]] },
    { 'hidden_write', counting .. [[
local entry = do(n: U32): U32
    local state = Counting { count = 0, step = 3 }
    local alias = Ref state
    local total = U32 0
    for i: U32 = 1, n do
        if alias.count == 0 then total = total + 10 else total = total + 20 end
        alias:hit
    end
    return total
end
export entry
]] },
    { 'restored_alias', counting .. [[
local entry = do(n: U32): U32
    local state = Counting { count = 0, step = 3 }
    local alias = Ref state
    for i: U32 = 1, n do
        alias:hit
        alias.count = 0
    end
    return state.count + state.step
end
export entry
]] },
    { 'break_only', counting .. [[
local entry = do(n: U32): U32
    local state = Counting { count = 0, step = 3 }
    for i: U32 = 1, n do
        state.count = state.count + 1
        if i == 4 then state.step = 5; break end
    end
    return state.count + state.step
end
export entry
]] },
    { 'address_escape', counting .. [[
local change = do(state: Ref Counting): Unit
    state.step = state.step + 1
end
local entry = do(n: U32): U32
    local state = Counting { count = 0, step = 3 }
    local alias = Ref state
    for i: U32 = 1, n do
        alias:hit
        call change alias
    end
    return state.count
end
export entry
]] },
    { 'earlier_read', counting .. [[
local with_read = do(before: U32, alias: Ref Counting, n: U32): U32
    for i: U32 = 1, n do alias:hit end
    return before + alias.count
end
local entry = do(n: U32, seed: U32, flag: Bool): U32
    local state = Counting { count = seed, step = 3 }
    if flag then state.count = seed + 1 end
    return with_read state.count (Ref state) n
end
export entry
]] },
}

local saved, caught, attempts, snapshots, counts
local function pack(...) return { n = select('#', ...), ... } end
local function describe(value)
    if type(value) ~= 'table' then return 'host:' .. tostring(value) end
    local kind = rawget(value, 'k')
    if kind == 'known' then return 'K:' .. tostring(rawget(value, 'v')) end
    if kind == 'dyn' then return 'D' end
    if kind == 'ref' then return 'Ref' end
    if kind == 'agg' then
        local fields = {}
        for _, field in ipairs(rawget(value, 'T').fields) do
            fields[#fields + 1] = field.name .. '=' .. describe(rawget(value, 'f')[field.name])
        end
        return '{' .. table.concat(fields, ',') .. '}'
    end
    return kind or rawget(value, 'pk') or 'host:table'
end
local function arguments(frame)
    local out = {}
    for i, value in ipairs(frame.args) do
        local parameter = frame.desc.params[i]
        out[#out + 1] = (parameter and parameter.name or tostring(i)) .. '=' .. describe(value)
    end
    return table.concat(out, ' ')
end
local function install(object, name, replacement)
    saved[#saved + 1] = { object, name, object[name] }
    object[name] = replacement(object[name])
end

local function install_trace()
    -- "caught" is the nearest watched boundary, not a claim about the throw line.
    local function watch(object, name)
        install(object, name, function(original)
            return function(...)
                local result = pack(pcall(original, ...))
                if not result[1] then
                    local request = result[2]
                    if type(request) == 'table' and request.nua_signal then
                        caught[request] = caught[request] or name
                    end
                    error(request, 0)
                end
                return unpack(result, 2, result.n)
            end
        end)
    end
    for _, name in ipairs { 'loop_write', 'loop_escape', 'jump_next', 'apply' } do watch(Builder, name) end
    for _, name in ipairs { 'tail', 'loop_next', 'loop_exit', 'loop_break' } do watch(S, name) end
    for _, name in ipairs { 'run_inline', 'run_loop' } do
        install(Builder, name, function(original)
            return function(builder, frame)
                counts.attempts = counts.attempts + 1
                local id = counts.attempts
                attempts[frame], snapshots[frame.snap] = id, id
                print(('  A%d %s %s %s'):format(id, frame.mode,
                    frame.word and frame.word.name or frame.kind, arguments(frame)))
                local result = pack(pcall(original, builder, frame))
                if not result[1] then
                    local request = result[2]
                    if type(request) == 'table' and request.nua_signal then
                        local target = attempts[request.frame] or '?'
                        if request.frame == frame then
                            counts[request.nua_signal] = (counts[request.nua_signal] or 0) + 1
                            local mask = {}
                            for position, value in pairs(request.widen or {}) do
                                mask[#mask + 1] = tostring(position) .. '=' .. (value == true and 'D' or describe(value))
                            end
                            table.sort(mask)
                            print(('    %s target=A%s mode=%s widen=[%s] adopt=%s escape=%s caught=%s'):format(
                                request.nua_signal, target, request.mode or '-', table.concat(mask, ','),
                                request.adopt and request.adopt.name or '-', request.escape and request.escape.name or '-',
                                caught[request] or name))
                        else
                            print(('    forward %s target=A%s'):format(request.nua_signal, target))
                        end
                    end
                    error(request, 0)
                end
                -- run_frame can still discard completed inline output to use
                -- the shared definition discovered by recursive re-entry.
                print(('    complete A%d'):format(id))
                return unpack(result, 2, result.n)
            end
        end)
    end
    install(Builder, 'rollback', function(original)
        return function(builder, snapshot)
            counts.rollbacks = counts.rollbacks + 1
            print(('    rollback A%s suffix=%d locals=%d'):format(snapshots[snapshot] or '?',
                #snapshot.block - snapshot.n, #(builder.fn and builder.fn.locals or {}) - (snapshot.locals or 0)))
            return original(builder, snapshot)
        end
    end)
    install(Builder, 'snapshot_read', function(original)
        return function(builder, place, registration)
            local was_done = registration.done
            local result = original(builder, place, registration)
            if not was_done and registration.done then
                counts.captures = counts.captures + 1
                print('    capture earlier read: ' .. place.name)
            end
            return result
        end
    end)
end

local previous_policy = S.call_policy
S.call_policy = 'written'
saved, caught, attempts, snapshots = {}, {}, {}, {}
install_trace()
local ok, failure = pcall(function()
    for _, case in ipairs(cases) do
        caught, attempts, snapshots = {}, {}, {}
        counts = { attempts = 0, tail = 0, restart = 0, rollbacks = 0, captures = 0 }
        print('\nCASE ' .. case[1])
        local emitted, module = nua.compile(case[2], 'trace_' .. case[1] .. '.nua', { no_c = true })
        assert(emitted == nil, 'trace must not emit C')
        local loops = 0
        for _, fn in ipairs(module.functions) do
            G.walk_block(fn.body, function(statement) if statement.op == 'loop' then loops = loops + 1 end end)
        end
        print(('SUMMARY attempts=%d known_next=%d restarts=%d rollbacks=%d captures=%d functions=%d loops=%d'):format(
            counts.attempts, counts.tail, counts.restart, counts.rollbacks, counts.captures, #module.functions, loops))
    end
end)
for i = #saved, 1, -1 do
    local entry = saved[i]
    entry[1][entry[2]] = entry[3]
end
S.call_policy = previous_policy
if not ok then error(failure, 0) end
print('\nObserved ten staging-only cases; no preparation or native acceptance claim.')
