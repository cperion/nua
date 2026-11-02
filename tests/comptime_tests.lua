-- Named tests are ordinary program construction, never residual test functions.
local root = arg[0]:match('^(.*)/tests/[^/]*$') or '.'
package.path = root .. '/?.lua;' .. package.path
local nua = require 'nua'
local stage = require 'nua.stage'
local passed = 0
local path = root .. '/build/comptime-tests/case.nua'
local function check(name, ok, detail)
    assert(ok, name .. (detail and ('\n' .. tostring(detail)) or ''))
    passed = passed + 1
end
local function compile(source)
    return nua.compile(source, path)
end
local function reject(name, source, fragments)
    local ok, err = pcall(compile, source)
    check(name .. ' rejected', not ok, err)
    for _, fragment in ipairs(fragments) do
        check(name .. ': ' .. fragment, tostring(err):find(fragment, 1, true) ~= nil, err)
    end
    check(name .. ' restores builder', stage.builder() == nil)
end

local source = [[
local add = do(a: U32, b: U32): U32 = a + b

test "addition" do(): Unit
    assert(add 2 2 == 4)
    assert(call add 40 2 == 42)
end

local Counter = struct { value: U32 }
local bump = do(counter: Ref Counter): Unit
    counter.value = counter.value + 1
end

test "known mutation and loops" do(): Unit
    local counter = Counter { value = 0 }
    for i: U32 = 1, 4 do
        bump(Ref counter)
    end
    assert(counter.value == 4)
end

test "plain Lua and assertion results" do
    local marker = {}
    local value, message, missing, last = assert(marker, "message", nil, 42)
    assert(value == marker and message == "message" and missing == nil and last == 42)
    assert(0)
    assert("")
    assert(host(add 3 4) == 7)
    local condition = Bool true
    local native, detail = assert(condition, "known native Bool")
    assert(native == condition and detail == "known native Bool")
end

test "outer" do
    test "inner" do(): Unit
        assert(U64 0xffffffffffffffffULL + 1 == 0)
    end
end

test "return is not an assertion" do
    return false
end
]]
local code, mod = compile(source)
local empty = compile('')
-- Type/library construction can discover headers even when no native code remains.
local function without_includes(text) return text:gsub('#include[^\n]*\n', '') end
check('successful tests leave no residual code', without_includes(code) == without_includes(empty), code)
check('no residual test functions or exports', #mod.functions == 0 and #mod.exports == 0)
check('no test registry or residual statements', mod.tests == nil and stage.emitted() == 0)
check('old check binding removed', nua.prelude().check == nil and stage.check == nil)

local with_tests, exported = compile(source .. '\nexport add\n')
local baseline = compile('local add = do(a: U32, b: U32): U32 = a + b\nexport add\n')
check('adjacent tests do not change the residual export', without_includes(with_tests) == without_includes(baseline),
    with_tests)
check('only the program word is exported', #exported.exports == 1 and #exported.functions == 1
    and exported.exports[1].cname == 'add')

reject('host assertion', [[
test "host failure" do
    assert(false, "host detail")
end
]], { 'test "host failure"', 'case.nua:2:', 'host detail' })
reject('missing host condition', [[
test "missing condition" do
    assert()
end
]], { 'test "missing condition"', 'value expected' })
reject('native assertion', [[
test "native failure" do(): Unit
    assert(U32 2 + 2 == 5, "native detail")
end
]], { 'test "native failure"', 'case.nua:2:', 'native detail' })
reject('native Bool in plain Lua', [[
test "false native Bool" do
    assert(Bool false)
end
]], { 'test "false native Bool"', 'assertion failed!' })
reject('unknown assertion', [[
test "unknown Bool" do
    assert(dynamic(Bool true))
end
]], { 'test "unknown Bool"', 'assert condition must be known at compile time' })
reject('nonboolean native condition', [[
test "native integer" do
    assert(U32 1)
end
]], { 'test "native integer"', 'a native condition must be Bool' })
reject('unknown argument', [[
local positive = do(n: U32): Bool = n > 0
test "unknown argument" do
    assert(positive(dynamic(U32 1)))
end
]], { 'test "unknown argument"', "argument 'n' not known" })
reject('foreign effect', [[
local effect = extern("test_effect_must_not_run", { U32 }, Unit)
test "foreign effect" do(): Unit
    effect 7
end
]], { 'test "foreign effect"', 'cannot evaluate at compile time', 'test_effect_must_not_run' })
reject('runtime storage', [[
local Node = struct { value: U32 }
test "runtime storage" do(): Unit
    local nodes = (Store Node) {}
    nodes:add Node { value = 1 }
end
]], { 'test "runtime storage"', 'compile time' })
reject('nested failure', [[
test "outer failure" do
    test "inner failure" do(): Unit
        assert(false)
    end
end
]], { 'test "outer failure"', 'test "inner failure"', 'case.nua:3:' })
reject('test in residual code', [[
local entry = do(): Unit
    test "runtime declaration" do end
end
export entry
]], { 'test blocks run during program construction, not in residual code' })
reject('assertion is not a runtime trap', [[
local entry = do(condition: Bool): Unit
    assert condition
end
export entry
]], { 'assert condition must be known at compile time' })
reject('partial test body', [[
local body = do(n: U32): Unit end
test "partial body" (body)
]], { 'the body must take no arguments' })
reject('invalid name', [[test 42 do end]], { 'the name must be text known while compiling' })
reject('invalid body', [[test "not a block" 42]], { 'takes a block' })

-- A failed assertion stops module construction; no subsequent block is run.
local reached = false
local saved = package.preload.comptime_test_reached
package.preload.comptime_test_reached = function() reached = true; return true end
local ok, err = pcall(compile, [[
test "stop compilation" do assert(false) end
require "comptime_test_reached"
]])
package.preload.comptime_test_reached = saved
check('fail fast during program construction', not ok and not reached, err)

-- Source modules run their adjacent tests when loaded, with ordinary require caching.
for _ = 1, 2 do
    local _, module = nua.compile([[
local a = require "named_tests"
local b = require "named_tests"
assert(a == b and a.runs == 1)
]], root .. '/tests/modules/comptime_main.nua')
    check('loaded module tests leave no registry or exports', module.tests == nil and #module.exports == 0)
end

local imported_ok, imported_err = pcall(nua.compile, 'require "named_failure"',
    root .. '/tests/modules/comptime_main.nua')
check('required module failure names its assertion line', not imported_ok
    and tostring(imported_err):find('test "failure in required module"', 1, true)
    and tostring(imported_err):find('named_failure.nua:2:', 1, true)
    and tostring(imported_err):find('module assertion', 1, true), imported_err)

local after = compile(source)
check('independent compilation after failures', without_includes(after) == without_includes(code)
    and stage.builder() == nil, after)

-- Neither normal checking nor C output may require a C compiler or libgccjit.
local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local build = root .. '/build/comptime-tests'
assert(os.execute('mkdir -p ' .. quote(build)) == 0)
local failure = build .. '/failure.nua'
local file = assert(io.open(failure, 'w'))
file:write('test "CLI failure" do(): Unit\n    assert(false, "CLI assertion")\nend\n')
file:close()
local cli = 'CC=/bin/false NUA_GCCJIT=/no-gccjit.so luajit ' .. quote(root .. '/nua.lua')
local function command(args)
    local process = assert(io.popen(cli .. ' ' .. args .. ' 2>&1; echo __rc=$?'))
    local output = process:read '*a'
    process:close()
    local status = tonumber(output:match('__rc=(%d+)%s*$'))
    return status, output
end
local status, output = command('check ' .. quote(root .. '/examples/tests.nua'))
check('ordinary check needs no backend execution', status == 0, output)
status, output = command(quote(root .. '/examples/tests.nua'))
check('ordinary C emission leaves no test entry points', status == 0 and not output:find('nua_test_', 1, true), output)
status, output = command('check ' .. quote(failure))
check('ordinary check reports named test failure', status == 1
    and output:find('test "CLI failure"', 1, true)
    and output:find('failure.nua:2:', 1, true)
    and output:find('CLI assertion', 1, true), output)
status, output = command(quote(failure))
check('ordinary compilation also rejects failed tests', status == 1
    and output:find('CLI assertion', 1, true), output)

print(('%d compile-time test checks passed'):format(passed))
