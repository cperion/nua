-- Actual staging observations of recursive and mixed-origin owner completion.
-- No preparation, C emission, native execution, or replacement-layout proof.
package.path = './?.lua;./.local/share/lua/5.1/?.lua;' .. package.path
package.loaded['nua.driver_loaded'] = true
local nua = dofile('nua.lua')
local S = require 'nua.stage'
local G = require 'nua.cgen'
local cases = {
    { 'recursive_forward', [[
local function gather(n: U32): Grow U32
    if n == 0 then return Grow(U32) {} end
    local rest = gather (n - 1)
    rest:push n
    return rest
end
local entry = do(n: U32): U64
    local result = call gather n
    local moved = result
    return moved.length
end
export entry
]] },
    { 'recursive_combine', [[
local function gather(n: U32): Grow U32
    if n == 0 then
        local leaf = Grow(U32) {}
        leaf:push 1
        return leaf
    end
    local left = gather (n - 1)
    local right = gather (n - 1)
    local out = Grow(U32) {}
    out:push (U32 left.length + U32 right.length)
    return out
end
local entry = do(n: U32): U64
    local result = call gather n
    local moved = result
    local observed = moved.length
    moved = Grow(U32) {}
    return observed + moved.length
end
export entry
]] },
    { 'mixed_argument_and_fresh', [[
local choose = do(given: Grow U32, flag: Bool): Grow U32
    local fresh = Grow(U32) {}
    fresh:push 7
    if flag then return given end
    return fresh
end
local entry = do(flag: Bool): U64
    local input = Grow(U32) {}
    input:push 3
    local result = call choose input flag
    local moved = result
    return moved.length
end
export entry
]] },
    { 'older_result_growth', [[
local function gather(n: U32): Grow U32
    local out = Grow(U32) {}
    if n == 0 then return out end
    local inner = gather (n - 1)
    out:push (U32 inner.length)
    return out
end
local entry = do(n: U32): U64
    local result = gather n
    return result.length
end
export entry
]], 'lies above it on the result stack' },
}
local policy = S.call_policy
local ok, err = pcall(function()
    S.call_policy = 'written'
    for _, case in ipairs(cases) do
        local success, result = pcall(function()
            local c, module = nua.compile(case[2], 'owner_completion_' .. case[1] .. '.nua', { no_c = true })
            assert(c == nil)
            return module
        end)
        print('CASE ' .. case[1])
        if case[3] then
            assert(not success and tostring(result):find(case[3], 1, true), tostring(result))
            print('  expected rejection: ' .. tostring(result))
        else
            assert(success, result)
            for _, fn in ipairs(result.functions) do
                if fn.word and (fn.word.name == 'gather' or fn.word.name == 'choose' or fn.word.name == 'entry') then
                    local captures = 0
                    G.walk_block(fn.body, function(stmt)
                        if stmt.what == 'the top before a call' then captures = captures + 1 end
                    end)
                    print(('  %s result_stacks=%d returns_argument=%s precall_captures=%d'):format(
                        fn.word.name, fn.result_stacks or 0, tostring(not not next(fn.returns_param or {})), captures))
                end
            end
        end
    end
end)
S.call_policy = policy
if not ok then error(err, 0) end
print('Three cases staged; one rejected as expected. Native cleanup and replacement planning remain unproved.')
