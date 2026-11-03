-- The trailing colon: a colon that ends a line (optionally after parameter names)
-- is `do(..)`, `do(names)` or `do(scope..)`. Annotation colons never change.
local root = arg[0]:match('^(.*)/tests/[^/]*$') or '.'
package.path = root .. '/?.lua;' .. package.path
local macro = require 'macro'
require 'macro.builtin'
require 'macro.nua'
local lexer = require 'macro.lexer'
local colon = require 'nua.colon'
local fmt = require 'nua.fmt'
local passed = 0
local function check(name, condition, detail)
    assert(condition, name .. (detail and ('\n' .. detail) or ''))
    passed = passed + 1
end
local function normal(code)
    local parts = {}
    for _, tk in ipairs(lexer.scan_raw_tokenlist(code)) do
        if tk[1] ~= 'space' and tk[1] ~= 'comment' then parts[#parts + 1] = tk[2] end
    end
    return table.concat(parts, '\0')
end
local function translated(source, name)
    return assert(macro.substitute_tostring(source, name))
end

-- every colon form translates exactly as the do-form it stands for
local pairs_of = {
    { 'anonymous', 'with_buffer n:\n    go\nend\n', 'with_buffer n do(..)\n    go\nend\n' },
    { 'after a call', 'view_of(p, n):\n    go\nend\n', 'view_of(p, n) do(..)\n    go\nend\n' },
    { 'names', 'xs:each: key value\n    go\nend\n', 'xs:each do(key, value)\n    go\nend\n' },
    { 'one name', 'xs:each: x\n    go x\nend\n', 'xs:each do(x)\n    go x\nend\n' },
    { 'named opening', 'tasks: scope..\n    go\nend\n', 'tasks do(scope..)\n    go\nend\n' },
    { 'trailing comment', 'xs:each: x -- note\n    go x\nend\n', 'xs:each do(x) -- note\n    go x\nend\n' },
    { 'in an initializer', 'local total = view_of(p, n): bytes\n    go\nend\n',
      'local total = view_of(p, n) do(bytes)\n    go\nend\n' },
    { 'nested', 'a:\n    b: x\n        go x\n    end\nend\n', 'a do(..)\n    b do(x)\n        go x\n    end\nend\n' },
}
for _, case in ipairs(pairs_of) do
    check('colon block: ' .. case[1], normal(translated(case[2], case[1]))
        == normal(translated(case[3], case[1])), translated(case[2], case[1]))
end

-- annotation colons, labels and method calls are not blocks
local unchanged = {
    { 'local annotation', 'local s: Store Node\n' },
    { 'local list annotation', 'local a, b: U32\n' },
    { 'typed lambda', 'local f = do(a: U32): U32\n    return a\nend\n' },
    { 'named function', 'function T:m(n: U32): Unit\n    go\nend\n' },
    { 'local function', 'local function f(n: U32): U32\n    return n\nend\n' },
    { 'label', 'do\n    goto done\n    ::done::\nend\n' },
    { 'method statement', 'xs:refresh\nxs:each(f)\n' },
    { 'table field', 'local t = {\n    x: 1,\n}\n' },
}
for _, case in ipairs(unchanged) do
    local tokens = lexer.scan_raw_tokenlist(case[2])
    local out = colon.rewrite(lexer.scan_raw_tokenlist(case[2]))
    local same = #out == #tokens
    for i = 1, #tokens do same = same and out[i] and out[i][2] == tokens[i][2] end
    check('not a block: ' .. case[1], same)
end

-- line numbers survive the rewrite
local located = translated('local n = 0\nxs:each: x\n    n = n + x\nend\nlocal bad = nope.nope\n', 'lines.nua')
check('line numbers stay put', select(2, located:gsub('\n', '\n')) == 5, located)

-- a colon block runs
local host = [[
local each = do(body)
    body(1)
    body(2)
    body(3)
end
local total = 0
each: x
    total = total + x
end
assert(total == 6)
local twice = do(body) = body(2) + body(3)
local value = twice: y
    return y * 10
end
assert(value == 50)
]]
assert(loadstring(translated(host, 'host.nua'), '@host.nua'))()
check('colon blocks run as host code', true)

-- the formatter prints the colon form for untyped trailing blocks, and only there
local function formatted(name, source, expected, options)
    local out = fmt.format(source, options, name)
    check(name, out == expected, out)
    check(name .. ': idempotent', fmt.format(out, options, name) == out)
end
formatted('fmt: do-form becomes colon', 'with_buffer n do(..)\n    go\nend\n', 'with_buffer n:\n    go\nend\n')
formatted('fmt: names', 'xs:each do(key, value)\n    go\nend\n', 'xs:each: key value\n    go\nend\n')
formatted('fmt: opened name', 'tasks do(scope..)\n    use scope\nend\n', 'tasks: scope..\n    use scope\nend\n')
formatted('fmt: colon form kept', 'xs:each: x\n    go x\nend\n', 'xs:each: x\n    go x\nend\n')
formatted('fmt: typed lambda untouched', 'local f = do(a: U32): U32\n    return a\nend\n',
    'local f = do(a: U32): U32\n    return a\nend\n')
formatted('fmt: inline block untouched', 'xs:each do(x) go x end\n', 'xs:each do(x) go x end\n')
formatted('fmt: nullary block untouched', 'spawn do\n    go\nend\n', 'spawn do\n    go\nend\n')
formatted('fmt: block style do', 'xs:each: x\n    go x\nend\n', 'xs:each do(x)\n    go x\nend\n',
    { block_style = 'do' })
check('fmt: bad block style', not pcall(fmt.format, 'x = 1\n', { block_style = 'ruby' }))

print(('%d trailing colon checks passed'):format(passed))
