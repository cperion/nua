-- Terminating paths participate in joins, not as fabricated return values.
-- No preparation, runtime attachment, C emission or native compilation.
local root = arg[0]:match('^(.*)/tests/[^/]*$') or '.'
package.path = root .. '/?.lua;' .. root .. '/.local/share/lua/5.1/?.lua;' .. package.path
local nua = require 'nua'
local S = require 'nua.stage'
local G = require 'nua.cgen'
local cases = {
    { 'root_trap', 1, 0, [[
local entry = do(): U32
    trap "stop"
end
export entry
]] },
    { 'inline_trap', 1, 0, [[
local stop = do(): U32
    trap "stop"
end
local entry = do(): U32 = stop()
export entry
]] },
    { 'two_trapping_paths', 2, 0, [[
local stop = do(flag: Bool): U32
    if flag then trap "left" else trap "right" end
end
local entry = do(flag: Bool): U32 = stop flag
export entry
]] },
    { 'one_returning_path', 1, 1, [[
local checked = do(flag: Bool): U32
    if flag then return 7 end
    trap "stop"
end
local entry = do(flag: Bool): U32 = checked flag
export entry
]] },
    { 'match_trapping_handler', 1, 1, [[
local Choice = oneof { absent: Unit, present: U32 }
local checked = do(value: Choice): U32
    return value with
        absent = do(): U32
            trap "absent"
        end
        present = do(n: U32): U32 return n end
    end
end
local entry = do(value: Choice): U32 = checked value
export entry
]] },
    { 'callback_trap', 1, 0, [[
local apply = do(body): Unit
    body()
end
local entry = do(): U32
    apply do() trap "stop" end
end
export entry
]] },
    { 'borrow_return_or_trap', 1, 1, [[
local Box = struct { value: U32 }
local checked = do(value: Ref Box, flag: Bool): Ref Box
    if flag then return value end
    trap "stop"
end
local entry = do(value: Ref Box, flag: Bool): U32
    local r = checked value flag
    return r.value
end
export entry
]] },
    { 'unit_fallthrough_still_returns', 0, 1, [[
local touch = do(value: Ref U32): Unit
    value = value + 1
end
local entry = do(value: Ref U32): U32
    touch value
    return value
end
export entry
]] },
}
local policy = S.call_policy
local ok, err = pcall(function()
    S.call_policy = 'written'
    for _, case in ipairs(cases) do
        local c, module = nua.compile(case[4], 'trap_' .. case[1] .. '.nua', { no_c = true })
        assert(c == nil, 'test must not emit C')
        local entry
        for _, fn in ipairs(module.functions) do
            if fn.word and fn.word.name == 'entry' then entry = fn end
        end
        assert(entry, 'entry definition missing')
        local traps, returns = 0, 0
        G.walk_block(entry.body, function(statement)
            if statement.op == 'trap' then traps = traps + 1 end
            if statement.op == 'ret' then returns = returns + 1 end
        end)
        assert(traps == case[2], case[1] .. ': incorrect trap count ' .. traps)
        assert(returns == case[3], case[1] .. ': incorrect return count ' .. returns)
        assert(S.builder() == nil, 'builder leaked')
        print('PASS ' .. case[1])
    end
end)
S.call_policy = policy
if not ok then error(err, 0) end
print(('PASS: %d trap staging/IR checks; no native execution'):format(#cases))
