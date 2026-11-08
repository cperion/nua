-- Observe owner allocations and result-to-element placement, not acceptance.
-- Run: luajit docs/design/compiler-inventory/storage-probe.lua
-- no_c: no preparation, runtime attachment, C emission or native compilation.
package.path = './?.lua;./.local/share/lua/5.1/?.lua;' .. package.path
package.loaded['nua.driver_loaded'] = true
local nua = dofile('nua.lua')
local S = require 'nua.stage'
local Builder = S.Builder
local choose = [[
local choose_owner = do(flag: Bool): Grow U32
    local left = Grow(U32) {}
    local right = Grow(U32) {}
    left:push 1
    right:push 2
    if flag then return left end
    return right
end
]]
local cases = {
    { 'inline_known', 'local xs = choose_owner true\nreturn xs[0]' },
    { 'inline_dynamic', 'local xs = choose_owner flag\nreturn xs[0]' },
    { 'call_known', 'local xs = call choose_owner true\nreturn xs[0]' },
    { 'call_dynamic', 'local xs = call choose_owner flag\nreturn xs[0]' },
    { 'element_known_result', [[local groups = Grow(Grow U32) {}
groups:push (call choose_owner true)
return groups[0][0]
]] },
    { 'element_result', [[local groups = Grow(Grow U32) {}
groups:push (call choose_owner flag)
return groups[0][0]
]] },
}
local original_alloc, original_adopt = Builder.gs_alloc, Builder.adopt_tenant
local policy = S.call_policy
local ok, err = pcall(function()
    S.call_policy = 'written'
    for _, case in ipairs(cases) do
        local attempts, count, allocations, adoptions = {}, 0, {}, {}
        Builder.gs_alloc = function(b, p, fields)
            local indices = original_alloc(b, p, fields)
            local name = rawget(p, 'name')
            if name == 'left' or name == 'right' then
                if not attempts[b.fn] then count = count + 1; attempts[b.fn] = count end
                local out = {}
                for _, k in ipairs(indices) do
                    out[#out + 1] = type(k) == 'number' and ('local:' .. k)
                        or (k.res ~= nil and ('result:' .. k.res) or 'arena')
                end
                allocations[#allocations + 1] = ('attempt=%d %s=%s'):format(
                    attempts[b.fn], name, table.concat(out, ','))
            end
            return indices
        end
        Builder.adopt_tenant = function(b, holder, dst, src, position)
            local slots = b:slots_of(src)
            local ordinal = slots[1] and slots[1].ordinal
            local call = ordinal and b.result_calls and b.result_calls[ordinal]
            local adopted = original_adopt(b, holder, dst, src, position)
            adoptions[#adoptions + 1] = ('adopted=%s call_arena_ok=%s'):format(
                tostring(adopted), call and tostring(call.arena_ok) or 'not-call')
            return adopted
        end
        local source = choose .. '\nlocal entry = do(flag: Bool): U32\n'
            .. case[2] .. '\nend\nexport entry\n'
        local emitted, module = nua.compile(source, 'storage_probe_' .. case[1] .. '.nua', { no_c = true })
        assert(emitted == nil, 'probe must not emit C')
        print('CASE ' .. case[1])
        for _, line in ipairs(allocations) do print('  ' .. line) end
        for _, line in ipairs(adoptions) do print('  ' .. line) end
        local definitions = 0
        for _, fn in ipairs(module.functions) do
            if fn.word and fn.word.name == 'choose_owner' then
                definitions = definitions + 1
                print(('  completed choose_owner result_stacks=%d dynamic_flag=%s'):format(
                    fn.result_stacks or 0, tostring(not not fn.dynamic_pos[1])))
            end
        end
        print(('  allocation_attempts=%d choose_definitions=%d'):format(count, definitions))
    end
end)
Builder.gs_alloc, Builder.adopt_tenant, S.call_policy = original_alloc, original_adopt, policy
if not ok then error(err, 0) end
print('Observed staging only; no replacement, native-result or no-copy acceptance claim.')
