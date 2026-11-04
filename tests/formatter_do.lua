-- Focused formatter regression: a same-line do argument needs no call parens.
local root = arg[0]:match('^(.*)/tests/[^/]*$') or '.'
package.path = root .. '/?.lua;' .. package.path
local fmt = require 'nua.fmt'
local passed = 0
local function check(name, condition, detail)
    assert(condition, name .. (detail and ('\n' .. detail) or ''))
    passed = passed + 1
end
local function formatted(name, source, expected, options)
    local result = fmt.format(source, options, name)
    check(name, result == expected, result)
    check(name .. ': idempotent', fmt.format(result, options, name) == result)
    return result
end
formatted('host method block', 'items:each(do(item)\nconsume item\nend)',
    'items:each: item\n    consume item\nend\n')
formatted('host plain block', 'visit(do\nwork()\nend)',
    'visit do\n    work\nend\n')
formatted('inline block', 'visit(do(x) return x end)', 'visit do(x) return x end\n')
formatted('comments in body', 'visit(do(x) -- keep this\n-- and this\nconsume x\nend)',
    'visit: x  -- keep this\n    -- and this\n    consume x\nend\n')
formatted('already bare', 'visit do(x)\nconsume x\nend',
    'visit: x\n    consume x\nend\n')
formatted('preserve option', 'visit(do(x)\nconsume x\nend)',
    'visit(do(x)\n        consume x\n    end)\n', { call_style = 'preserve' })
formatted('next-line do joins owning call', 'visit(\ndo(x)\nconsume x\nend)',
    'visit: x\n    consume x\nend\n')
check('invalid split owning call rejected', not pcall(fmt.format, 'visit\n(do end)'))
formatted('multiple arguments stay together', 'visit(1, do(x)\nconsume x\nend)',
    'visit(1, do(x)\n        consume x\n    end)\n')
formatted('callee after call', 'visit(1)(do(x)\nconsume x\nend)',
    'visit 1: x\n    consume x\nend\n')
formatted('native block', 'local f=do():Unit\nvisit(do(x)\nconsume x\nend)\nend',
    'local f = do(): Unit\n    visit: x\n        consume x\n    end\nend\n')
formatted('nested do blocks', 'visit(do(x)\nother(do(y)\nconsume y\nend)\nend)',
    'visit: x\n    other: y\n        consume y\n    end\nend\n')

-- Exercise the actual macro translator independently of runtime/compiler
-- initialization. Execute the host case; compare generated staged Lua for the
-- native case, rather than relying only on the formatter's parser fingerprint.
package.path = root .. '/?/init.lua;' .. package.path
local mua = require 'mua.init'
local front = require 'nua.front'
local dlex = require 'mua.lex'
local function translate(source, name) return mua.translate(source, name, { host = front.host(name) }) end
local function equivalent(name, source, execute)
    local result = fmt.format(source, nil, name)
    local before = translate(source, name)
    local after = translate(result, name)
    local function normalize(code)
        local parts = {}
        for _, tk in ipairs(dlex.scan(code, name)) do
            if tk.t ~= 'space' and tk.t ~= 'comment' then parts[#parts + 1] = tk.v end
        end
        return table.concat(parts, '\0')
    end
    check(name .. ': same translated Lua', normalize(before) == normalize(after), after)
    if execute then
        assert(loadstring(before, '@' .. name))()
        assert(loadstring(after, '@' .. name))()
        check(name .. ': host assertions executed', true)
    end
end
equivalent('host_do.nua', [[
local each = do(body)
    body(1)
    body(2)
end
local total = 0
each(do(x)
    total = total + x
end)
assert(total == 3)
]], true)
equivalent('native_do.nua', [[
local twice = do(body) = body(2) + body(3)
local f = do(x: U32): U32
    return twice(do(y)
        return x + y
    end)
end
export f
]])
equivalent('host_minimal_calls.nua', [=[
local identity = do(x) = x
local curry = do(x) = do(y) = x + y
local total = 0
local consume = do(x) total = total + x end
consume(
    identity(--[[ argument ]] 3)
)
local n = curry(
    4
)(
    5
)
local visit = do(body) body(2) end
visit(
    do(x)
        consume(x -- keep this newline
        )
    end
)
assert(total == 5)
assert(n == 9)
]=], true)
equivalent('native_minimal_calls.nua', [=[
local f = do(x: U32): U32
    local n = U32(
        x
    )
    return add(--[[ argument ]] x)(
        n
    )
end
export f
]=])
print(('%d do-block formatter checks passed'):format(passed))
