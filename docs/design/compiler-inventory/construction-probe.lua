-- Observe call-site ownership across a scalar loop rebuild, not acceptance.
-- Run: luajit docs/design/compiler-inventory/construction-probe.lua
-- no_c: no preparation, runtime attachment, C emission or native compilation.
package.path = './?.lua;./.local/share/lua/5.1/?.lua;' .. package.path
package.loaded['nua.driver_loaded'] = true
local nua = dofile('nua.lua')
local S = require 'nua.stage'
local G = require 'nua.cgen'
local Builder = S.Builder
local source = [[
local bump = do(x: U32): U32 = x + 1
local function walk(k: U32, x: U32): U32
    local first = call bump x
    local second = call bump first
    if x == 0 then return k + second end
    return walk (k + 1) (x - 1)
end
local entry = do(x: U32): U32 = walk 0 x
export entry
]]

local original, policy = Builder.rollback, S.call_policy
local discarded, rollbacks = {}, 0
Builder.rollback = function(builder, snapshot)
    if builder.fn and snapshot.locals then
        for i = snapshot.locals + 1, #builder.fn.locals do
            discarded[builder.fn.locals[i]] = true
        end
    end
    rollbacks = rollbacks + 1
    return original(builder, snapshot)
end
S.call_policy = 'written'
local ok, emitted, module = pcall(nua.compile, source, 'construction_probe.nua', { no_c = true })
Builder.rollback, S.call_policy = original, policy
if not ok then error(emitted, 0) end
assert(emitted == nil, 'probe must not emit C')

local body_calls, body_discarded_reads = 0, 0
local metadata_calls, metadata_discarded_reads = 0, 0
local function reads_discarded(expression)
    return expression.op == 'read' and discarded[expression.place]
end
for _, fn in ipairs(module.functions) do
    G.walk_block(fn.body, nil, function(expression)
        if expression.op == 'call' then body_calls = body_calls + 1 end
        if reads_discarded(expression) then body_discarded_reads = body_discarded_reads + 1 end
    end)
    for _, call in ipairs(fn.call_nodes or {}) do
        metadata_calls = metadata_calls + 1
        G.walk_expr(call, function(expression)
            if reads_discarded(expression) then metadata_discarded_reads = metadata_discarded_reads + 1 end
        end)
    end
end
print(('functions=%d rollbacks=%d body_calls=%d metadata_calls=%d'):format(
    #module.functions, rollbacks, body_calls, metadata_calls))
print(('body_discarded_reads=%d metadata_discarded_reads=%d'):format(
    body_discarded_reads, metadata_discarded_reads))
print('Observed call metadata, not a native miscompilation or a replacement-acceptance result.')
