-- The project's source macro engine and standalone CLI, without any bundle.
local root = arg[0]:match('^(.*)/tests/[^/]*$') or '.'
local function q(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
local function capture(command)
    local p = assert(io.popen(command .. ' 2>&1; printf "\\n__STATUS__%d\\n" "$?"'))
    local text = p:read '*a'; p:close()
    local out, status = text:match('^(.*)\n__STATUS__(%d+)\n$')
    assert(status, text)
    return out, tonumber(status)
end
local passed = 0
local function check(label, command, status, contains, absent)
    local out, rc = capture(command)
    assert(rc == status and (not contains or out:find(contains, 1, true))
        and (not absent or not out:find(absent, 1, true)), label .. ': status ' .. tostring(rc) .. '\n' .. out)
    passed = passed + 1
    print('ok    macro: ' .. label)
end
local lua = q(arg[-1] or 'luajit')
local cli = 'timeout 20 ' .. lua .. ' ' .. q(root .. '/luam')
local fixtures = root .. '/tests/macros/fixtures/'
local function fixture(name) return q(fixtures .. name) end
package.path = root .. '/?.lua;' .. package.path
local macro = require 'macro'
assert(package.preload.macro == nil, 'the source engine must not come from package.preload')
assert(debug.getinfo(macro.substitute_tostring, 'S').source:match('macro%.lua$'), 'expected the source macro module')
local bundle = io.open(root .. '/luam.lua'); if bundle then bundle:close() end
assert(not bundle, 'retired runtime bundle is still present')
passed = passed + 1
check('plain program', cli .. ' ' .. fixture('ok.lua'), 0, 'fixture ok')
check('dump only', cli .. ' -d ' .. fixture('ok.lua'), 0, 'fixture ok')
check('standalone expression', cli .. ' -e ' .. q('print(1+1)'), 0, '2')
check('expression error status', cli .. ' -e ' .. q('error("boom")'), 1, 'boom')
check('anonymous traceback terminates', cli .. ' ' .. fixture('anon_error.lua'), 1, ':3:', '[string "')
check('lambda traceback terminates', cli .. ' -lmacro.let ' .. fixture('anon_error_lambda.lua'), 1, ':2:', '[string "')
check('named error status', cli .. ' ' .. fixture('named_error.lua'), 1, 'boom')
check('syntax error context', cli .. ' ' .. fixture('syntax_error.lua'), 1, 'preprocessed context of error')
check('missing file status', cli .. ' ' .. fixture('does_not_exist.lua'), 1, 'No such file')
check('macro error location', cli .. ' -lmacro.let ' .. fixture('macro_error.lua'), 1, 'macro_error.lua:1')
check('optional macro vocabulary', cli .. ' -lmacro.all -e ' .. q('print("vocabulary ok")'), 0, 'vocabulary ok')
check('expression lambdas and currying', cli .. ' -lmacro.let -e ' .. q([[
local mul = do(a) = do(b) = a * b
assert(mul 6 7 == 42)
local answer = do() = 42
assert(answer() == 42)
print('forms ok')
]]), 0, 'forms ok')
check('nested application in copied argument groups', cli .. ' -lmacro.let -e ' .. q([[
local identity = do(x) = x
local Box = do(fields) = fields
local Ref = do(x) = x
local item = 42
local result = identity Box { value = Ref item, nested = { Ref item } }
assert(result.value == 42 and result.nested[1] == 42)
assert(identity Box(Ref item) == 42)
local slots = { 42 }
local index = 1
assert(identity slots[Ref index] == 42)
local text = identity Box { value = "Ref__let_apply" }
assert(text.value == "Ref__let_apply")
print('copied groups ok')
]]), 0, 'copied groups ok')
check('native words inside expression factories', lua .. ' ' .. q(root .. '/nua.lua')
    .. ' ' .. fixture('expression_native.nua'), 0, 'read_expression', 'Ref__let_apply')
do
    local file = assert(io.open(fixtures .. 'expression_native.nua'))
    local source = file:read '*a'; file:close()
    local nua = require 'nua'
    local translated = nua.translate(source, fixtures .. 'expression_native.nua')
    assert(not translated:find('__let_apply', 1, true), translated)
    local code = nua.compile(source, fixtures .. 'expression_native.nua')
    local expression = code:match('uint32_t read_expression%b()%s*(%b{})')
    local block = code:match('uint32_t read_block%b()%s*(%b{})')
    local parenthesized = code:match('uint32_t read_parenthesized%b()%s*(%b{})')
    assert(expression and expression == block and expression == parenthesized, code)
    passed = passed + 1
    print('ok    macro: expression and block factories emit identical bodies')
end
check('exact hexadecimal integer suffixes in bare calls', cli .. ' -lmacro.let -e ' .. q([[
local identity = do(x) = x
local u = identity 0xffffffffffffffffULL
local s = identity 0x7fffffffffffffffLL
assert(type(u) == 'cdata' and u == 18446744073709551615ULL)
assert(type(s) == 'cdata' and s == 9223372036854775807LL)
print('hex suffixes ok')
]]), 0, 'hex suffixes ok')
check('two-dot opening keeps infix concatenation', cli .. ' -lmacro.let -e ' .. q([[
local named = do(ctx..) = label .. suffix
local unnamed = do(..) = label .. suffix
assert(named { label = 'a', suffix = 'b' } == 'ab')
assert(unnamed { label = 'c', suffix = 'd' } == 'cd')
local function args(...) return ... end
assert(args(42) == 42)
print('two dots ok')
]]), 0, 'two dots ok')
-- A host application may have unrelated argv and run outside this checkout.
local pwd = assert(io.popen('pwd')); local cwd = assert(pwd:read '*l'); pwd:close()
local absolute = root:sub(1, 1) == '/' and root or (cwd .. '/' .. root)
check('embedding ignores host argv and locates its own modules', 'timeout 20 ' .. lua .. ' -e ' .. q(
    'arg={[0]="/unrelated/host.lua",[1]="not-a-source-file"}; package.path=' .. string.format('%q', absolute .. '/?.lua;') .. '..package.path; '
    .. 'local saved=arg; local s=require "nua"; local c=s.compile("local f = do(x: U32): U32 = x + 1\\nexport f\\n", "inline.nua"); '
    .. 'assert(arg==saved); assert(c:find("x + 1u",1,true)); print("embedding ok")'), 0, 'embedding ok')
print(('%d macro source/CLI checks passed'):format(passed))
