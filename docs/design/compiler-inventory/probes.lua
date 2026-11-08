-- Historical inventory evidence, not an acceptance test of the rewrite.
-- Run from the repository root:
--   luajit docs/design/compiler-inventory/probes.lua
-- Only stages small words and rewrites synthetic IR. No C emission, compiler
-- subprocess, runtime loading or gccjit invocation. Observations intentionally
-- expose baseline discrepancies; process success does not mean semantics passed.
package.path = './?.lua;./.local/share/lua/5.1/?.lua;' .. package.path
local S = require 'nua.stage'
local T = require 'nua.types'
local G = require 'nua.cgen'

local function call_boundary(warm)
    S.reset()
    S.call_policy = 'written'
    local add = S.word {
        name = 'add_one', params = { { 'x', T.U32 } }, result = T.U32,
        body = function(x) S.ret(x + 1) end,
    }
    local entry = S.word {
        name = 'entry', params = {}, result = T.U32,
        body = function()
            if warm then add(T.U32(2)) end
            S.ret(S.boundary(add)(T.U32(2)))
        end,
    }
    S.export_word(entry, 'entry')
    local count = 0
    for _, fn in ipairs(S.module.functions) do
        for _, statement in ipairs(fn.body) do
            if statement.e and statement.e.op == 'call' then count = count + 1 end
        end
    end
    print(('warm=%s functions=%d calls=%d'):format(tostring(warm), #S.module.functions, count))
end

local function known_mutation()
    S.reset()
    S.call_policy = 'written'
    local entry = S.word {
        name = 'entry', params = {}, result = T.U32,
        body = function()
            local counter = S.decl(T.U32, T.U32(0), 'counter')
            local bump = S.word {
                name = 'bump', params = { { 'step', T.U32 } }, result = T.U32,
                body = function(step)
                    S.set(counter, S.value_of(counter) + step)
                    S.ret(S.value_of(counter))
                end,
            }
            local first = bump(T.U32(1))
            local second = bump(T.U32(1))
            local final = S.value_of(counter)
            print(('first=%s second=%s counter=%s'):format(
                tostring(first.v), tostring(second.v), tostring(final.v)))
            S.ret(final)
        end,
    }
    S.export_word(entry, 'entry')
end

local function cleanup_effects()
    S.reset()
    local expressions = {
        { op = 'call', ext = { cname = 'effect', params = {}, ret = T.U32 }, args = {}, T = T.U32 },
        { op = 'calli', a = { op = 'param', name = 'effect', T = T.fn({}, T.U32) }, args = {}, T = T.U32 },
        { op = 'rtcall', cname = 'effect', args = {}, T = T.U32 },
    }
    for _, expression in ipairs(expressions) do
        local place = S.new_place { pk = 'temp', T = T.U32, id = 1, name = 'unused' }
        local fn = { ret = T.Unit, body = {
            { op = 'let', place = place, e = expression }, { op = 'ret' },
        } }
        G.cleanup(fn)
        local first = fn.body[1]
        print(('%s commands=%d remaining=%s'):format(
            expression.op, #fn.body, first and first.op or 'none'))
    end
end

print('G02: cleanup effects')
cleanup_effects()
print('G03: explicit call after known evaluation')
call_boundary(false)
call_boundary(true)
print('G04: repeated known evaluation with pending mutation')
known_mutation()
