-- Nua's front end over Mua: native words inside expression factories, and embedding the
-- compiler in a host application with unrelated argv.
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
    print('ok    front: ' .. label)
end
local lua = q(arg[-1] or 'luajit')
local fixtures = root .. '/tests/front_fixtures/'
package.path = root .. '/?.lua;' .. root .. '/.local/share/lua/5.1/?.lua;' .. package.path
check('native words inside expression factories', lua .. ' ' .. q(root .. '/nua.lua')
    .. ' ' .. q(fixtures .. 'expression_native.nua'), 0, 'read_expression')
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
    print('ok    front: expression and block factories emit identical bodies')
end
-- A host application may have unrelated argv and run outside this checkout.
local pwd = assert(io.popen('pwd')); local cwd = assert(pwd:read '*l'); pwd:close()
local absolute = root:sub(1, 1) == '/' and root or (cwd .. '/' .. root)
check('embedding ignores host argv and locates its own modules', 'timeout 20 ' .. lua .. ' -e ' .. q(
    'arg={[0]="/unrelated/host.lua",[1]="not-a-source-file"}; package.path=' .. string.format('%q', absolute .. '/?.lua;') .. '..package.path; '
    .. 'local saved=arg; local s=require "nua"; local c=s.compile("local f = do(x: U32): U32 = x + 1\\nexport f\\n", "inline.nua"); '
    .. 'assert(arg==saved); assert(c:find("x + 1u",1,true)); print("embedding ok")'), 0, 'embedding ok')
print(('%d front-end checks passed'):format(passed))
