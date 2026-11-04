-- The Lua dialect (design macro-layer.md): its lexer, so far. Run from the repository root:
--   luajit tests/dialect.lua
local root = arg[0]:match('^(.*)/tests/[^/]*$') or '.'
package.path = root .. '/?.lua;' .. root .. '/?/init.lua;' .. package.path
local lex = require 'dialect.lex'

local passed, failed = 0, 0
local function check(name, ok, detail)
    if ok then passed = passed + 1
    else failed = failed + 1; print('FAIL  dialect: ' .. name .. (detail and ('\n' .. tostring(detail)) or '')) end
end

-- the significant tokens of a source, as "kind:text" strings
local function kinds(src)
    local out = {}
    for _, tk in ipairs(lex.scan(src, 't')) do
        if tk.t ~= 'space' and tk.t ~= 'comment' and tk.t ~= 'eof' then out[#out + 1] = tk.t .. ':' .. tk.v end
    end
    return table.concat(out, ' ')
end
local function tokens_are(name, src, expect)
    local ok, got = pcall(kinds, src)
    check('tokens: ' .. name, ok and got == expect, ok and ('got    ' .. got .. '\nexpect ' .. expect) or got)
end
local function rejects(name, src, expect)
    local ok, e = pcall(lex.scan, src, 't')
    check('rejects: ' .. name, not ok and tostring(e):find(expect, 1, true), ok and 'scanned' or e)
end

tokens_are('names and keywords', 'local goto_x = goto end_',
    'keyword:local name:goto_x =:= keyword:goto name:end_')
tokens_are('operators longest first', 'a...b..c.d==e<=f>=g~=h::i::',
    'name:a ...:... name:b ..:.. name:c .:. name:d ==:== name:e <=:<= name:f >=:>= name:g ~=:~= name:h ::::: name:i :::::')
tokens_are('dialect colons stay single', 'f x: key =: y',
    'name:f name:x ::: name:key =:= ::: name:y')
tokens_are('numbers', '1 1.5 .5 5. 1e5 1E-5 0x1F 0x1p4 0x.8P-1 42ULL 7ll 0x10ULL 3i 2.5i',
    'number:1 number:1.5 number:.5 number:5. number:1e5 number:1E-5 number:0x1F number:0x1p4 '
    .. 'number:0x.8P-1 number:42ULL number:7ll number:0x10ULL number:3i number:2.5i')
tokens_are('a hex e is a digit, not an exponent', '0x1e-1', 'number:0x1e -:- number:1')
tokens_are('strings', [===["a\"b" 'c\'d' "e\
f" [[x]] [==[y]]z]==] ]===],
    [===[string:"a\"b" string:'c\'d' string:"e\
f" string:[[x]] string:[==[y]]z]==]]===])
tokens_are('a bracket that opens no long string', 'a[1] b[ [=[s]=] ]',
    'name:a [:[ number:1 ]:] name:b [:[ string:[=[s]=] ]:]')
tokens_are('high bytes in names', 'local \206\187 = 1', 'keyword:local name:\206\187 =:= number:1')
tokens_are('a shebang line', '#!/usr/bin/env luajit\nreturn 1', 'shebang:#!/usr/bin/env luajit keyword:return number:1')

rejects('a malformed number', 'x = 1..2', "t:1:5: malformed number near '1..2'")
rejects('a suffix on a float', 'x = 1.5ULL', 'malformed number')
rejects('an unfinished string', 'x = "abc\ny', 't:1:5: unfinished string')
rejects('an unfinished long string', 'x = [==[abc]=]', 'unfinished long string')
rejects('an unfinished long comment', '--[[ abc', 'unfinished long comment')
rejects('a bad long bracket', 'x = [==x', 'invalid long string delimiter')
tokens_are('bitwise operators', 'a ~ ~b << 1 >> 2 & c | d ~= e',
    'name:a ~:~ ~:~ name:b <<:<< number:1 >>:>> number:2 &:& name:c |:| name:d ~=:~= name:e')
rejects('an unexpected symbol', 'x = a @ b', "unexpected symbol near '@'")
tokens_are('LuaJIT 3.0 operators', 'a != b && !c || d ?? e ? f : g?.h ~>> 1 |x| -> x || -> 1',
    'name:a !=:!= name:b &&:&& !:! name:c ||:|| name:d ??:?? name:e ?:? name:f ::: name:g ?.:?. name:h '
    .. '~>>:~>> number:1 |:| name:x |:| ->:-> name:x ||:|| ->:-> number:1')
tokens_are('compound assignments', 'a += 1 b -= 1 c *= 1 d /= 1 e %= 1 f &= 1 g |= 1 h ~= 1 i <<= 1 j >>= 1 k ~>>= 1 l ..= 1',
    'name:a +=:+= number:1 name:b -=:-= number:1 name:c *=:*= number:1 name:d /=:/= number:1 name:e %=:%= number:1 '
    .. 'name:f &=:&= number:1 name:g |=:|= number:1 name:h ~=:~= number:1 name:i <<=:<<= number:1 name:j >>=:>>= number:1 '
    .. 'name:k ~>>=:~>>= number:1 name:l ..=:..= number:1')
tokens_are('underscores and binary', '1_000 0xff_ff 1e1_0 1_0ULL 0b101 0B101LL 0b1_0 1_',
    'number:1_000 number:0xff_ff number:1e1_0 number:1_0ULL number:0b101 number:0B101LL number:0b1_0 number:1_')
tokens_are('a line directive in column 1', 'x = 1\n# 100 "f.lua"\ny = #t',
    'name:x =:= number:1 directive:# 100 "f.lua" name:y =:= #:# name:t')
rejects('a binary digit out of range', 'x = 0b102', 'malformed number')
rejects('a stray character', 'x = $', "t:1:5: unexpected symbol near '$'")

-- positions: lines across every kind of line break, columns in bytes
do
    local ts = lex.scan('a\r\nb\n\rc\rd\n--[[x\ny]] e "f\\\ng" h', 't')
    local at = {}
    for _, tk in ipairs(ts) do if tk.t == 'name' or tk.t == 'string' then at[#at + 1] = tk.v .. '@' .. tk.line .. ':' .. tk.col end end
    local got = table.concat(at, ' ')
    check('positions', got == 'a@1:1 b@2:1 c@3:1 d@4:1 e@6:5 "f\\\ng"@6:7 h@7:4', got)
end

-- the parser ---------------------------------------------------------------------------------
local parse = require 'dialect.parse'

-- a compact form of an expression or statement: calls as f(a)(b), lambdas as fn(p)
local show
local function list(xs) local o = {} for i, x in ipairs(xs or {}) do o[i] = show(x) end return table.concat(o, ', ') end
local function fnshow(fn)
    local ps = {}
    for i, p in ipairs(fn.params) do ps[i] = (p.unnamed and '..' or p.name) .. (p.opened and not p.unnamed and '..' or '') end
    if fn.vararg then ps[#ps + 1] = '...' end
    local head = (fn.arrow and 'arrow' or (fn.colon and 'colon' or 'fn')) .. '(' .. table.concat(ps, ' ') .. ')'
    if fn.result then head = head .. ':' .. show(fn.result) end
    if fn.expr then return head .. '=' .. show(fn.expr) end
    return head .. '{' .. list(fn.body) .. '}'
end
local function items(its)
    local o = {}
    for i, it in ipairs(its) do
        if it.kind == 'named' then o[i] = it.name .. '=' .. show(it.e)
        elseif it.kind == 'keyed' then o[i] = '[' .. show(it.key) .. ']=' .. show(it.e)
        elseif it.kind == 'spread' then o[i] = '..' .. show(it.e)
        else o[i] = show(it.e) end
    end
    return table.concat(o, ', ')
end
function show(n)
    local k = n.k
    if k == 'name' then return n.name
    elseif k == 'num' or k == 'str' then return n.text
    elseif k == 'nil' or k == 'true' or k == 'false' then return k
    elseif k == 'vararg' then return '...'
    elseif k == 'home' then return '..'
    elseif k == 'paren' then return n.literal and show(n.e) or ('(' .. show(n.e) .. ')')
    elseif k == 'field' then return show(n.obj) .. (n.safe and '?.' or '.') .. n.name
    elseif k == 'index' then return show(n.obj) .. (n.safe and '?.' or '') .. '[' .. show(n.key) .. ']'
    elseif k == 'call' then return show(n.fn) .. (n.safe and '?.' or '') .. '(' .. list(n.args) .. ')'
    elseif k == 'method' then return show(n.obj) .. (n.safe and '?.:' or ':') .. n.name .. (n.safe_call and '?.' or '') .. '(' .. list(n.args) .. ')'
    elseif k == 'lambda' then return fnshow(n.fn)
    elseif k == 'table' then return (n.with and 'with{' or '{') .. items(n.items) .. '}'
    elseif k == 'with' then return 'ctx{' .. items(n.items) .. '}'
    elseif k == 'spread' then return '..' .. show(n.e)
    elseif k == 'binop' then return '(' .. show(n.a) .. ' ' .. n.op .. ' ' .. show(n.b) .. ')'
    elseif k == 'unop' then return '(' .. n.op .. ' ' .. show(n.a) .. ')'
    elseif k == 'cond' then return '(' .. show(n.c) .. ' ? ' .. show(n.a) .. ' : ' .. show(n.b) .. ')'
    elseif k == 'struct' then
        local o = {}
        for i, f in ipairs(n.fields) do o[i] = f.name .. ':' .. show(f.type) end
        return (n.sum and 'Sum' or 'Struct') .. '{' .. table.concat(o, ', ') .. '}'
    elseif k == 'callstat' then return show(n.e)
    elseif k == 'assign' then return list(n.targets) .. ' = ' .. list(n.exprs)
    elseif k == 'compound' then return show(n.target) .. ' ' .. n.op .. '= ' .. show(n.e)
    elseif k == 'local' or k == 'const' then
        local o = {}
        for i, v in ipairs(n.names) do o[i] = v.name .. (v.type and (':' .. show(v.type)) or '') end
        return k .. ' ' .. table.concat(o, ', ') .. (#n.exprs > 0 and (' = ' .. list(n.exprs)) or '')
    elseif k == 'localfunction' then return (n.const and 'const ' or 'local ') .. 'function ' .. n.name .. ' ' .. fnshow(n.fn)
    elseif k == 'function' then return 'function ' .. table.concat(n.path, '.') .. (n.method and (':' .. n.method) or '') .. ' ' .. fnshow(n.fn)
    elseif k == 'return' then return 'return ' .. list(n.exprs)
    elseif k == 'open' then return 'open ' .. n.name .. (n.init and (' = ' .. show(n.init)) or '')
    elseif k == 'if' then return 'if ' .. show(n.clauses[1].cond) .. ' {' .. list(n.clauses[1].body) .. '}' .. (n.els and (' else {' .. list(n.els) .. '}') or '')
    elseif k == 'while' then return 'while ' .. show(n.cond) .. ' {' .. list(n.body) .. '}'
    elseif k == 'genfor' then return 'for ' .. table.concat(n.names, ',') .. ' in ' .. list(n.exprs) .. ' {' .. list(n.body) .. '}'
    elseif k == 'numfor' then return 'for ' .. n.var .. ' {' .. list(n.body) .. '}'
    elseif k == 'do' then return 'do {' .. list(n.body) .. '}'
    elseif k == 'label' then return '::' .. n.name .. '::'
    elseif k == 'goto' then return 'goto ' .. n.label
    elseif k == 'continue' or k == 'break' then return k
    end
    return '<' .. tostring(k) .. '>'
end
local function parses(name, src, expect)
    local ok, block = pcall(parse.parse, src, 't')
    local got = ok and list(block) or block
    check('parses: ' .. name, ok and got == expect, 'got    ' .. tostring(got) .. '\nexpect ' .. expect)
end
local function parse_rejects(name, src, expect)
    local ok, e = pcall(parse.parse, src, 't')
    check('parse rejects: ' .. name, not ok and tostring(e):find(expect, 1, true), ok and 'parsed' or e)
end

-- syntax.md §2.4
parses('juxtaposition', 'f a b', 'f(a)(b)')
parses('literal arguments across lines', 'f 1\n  "x"', 'f(1)("x")')
parses('a newline ends a name chain', 'f a\ng b', 'f(a), g(b)')
parses('an argument is a primary with its chain', 'f a.b x', 'f(a.b)(x)')
parses('a string argument takes its chain', 'f "x":rep 3', 'f("x":rep(3))')
parses('a literal chain stops at a table', 'f 21 {}', 'f(21)({})')
parses('a spaced group is the next argument', 'f a (b + 1)', 'f(a)((b + 1))')
parses('names go on after a spaced group', 'f (g x) y', 'f(g(x))(y)')
parses('an attached call ends the name chain', 'f a(b) x', 'f(a(b)), x()')
parses('application binds tighter than operators', 'x = f a + 1', 'x = (f(a) + 1)')
parses('a loop header ends at its do', 'for x in xs do f x end', 'for x in xs {f(x)}')
parses('a lambda argument', 'f(x) do(p) g p end', 'f(x)(fn(p){g(p)})')
parses('a statement do is Lua\'s', 'x = 1 do f() end', 'x = 1, do {f()}')
parses('zero-argument call statements', 'refresh\nscreen.refresh\nscreen:refresh', 'refresh(), screen.refresh(), screen:refresh()')
parses('field shorthand', 'p = P { .x, .y, z = 3 }', 'p = P({x=x, y=y, z=3})')
parses('keyed spread', 't = { ..a, k = 1 }', 't = {..a, k=1}')
parses('trailing colon', 'with_buffer n:\n  use n\nend', 'with_buffer(n)(colon(..){use(n)})')
parses('trailing colon on a method', 'xs:each: k v\n  f k v\nend', 'xs:each(colon(k v){f(k)(v)})')
parses('trailing colon opening a name', 'tasks: scope..\n  go\nend', 'tasks(colon(scope..){go()})')
parses('a block argument goes on applying', 'r = apply: v\n  return v\nend x', 'r = apply(colon(v){return v})(x)')
parses('=: assigns a block', 'local f =: x\n  return x\nend', 'local f = colon(x){return x}')
parses('with block', 'p = P with\n  x = 1\n  .y\n  z = f a\nend', 'p = P(with{x=1, y=y, z=f(a)})')
parses('with entries stop at the next entry', 'p = P with x = a y = b end', 'p = P(with{x=a, y=b})')
parses('contextual with', 'return with\n  x = 1\nend', 'return ctx{x=1}')
parses('with as a name', 'x = with + 1', 'x = (with + 1)')
parses('a handler entry', 'r = s with\n  done() = 0\n  failed(e) = e\nend', 'r = s(with{done=fn()=0, failed=fn(e)=e})')
parses('endall closes the spine', 'outer:each: a\n  inner:each: b\n    f a b\nendall\ng()',
    'outer:each(colon(a){inner:each(colon(b){f(a)(b)})}), g()')
parses('endall stops at a typed word', 'local w = do(): U32\n  xs:each: a\n    f a\n  endall\n  return 1\nend',
    'local w = fn():U32{xs:each(colon(a){f(a)}), return 1}')
parses('Struct and Sum', 'local P = Struct { x: F32, y: F32 }\nlocal S = Sum with\n  a: Unit\n  b: U32\nend',
    'local P = Struct{x:F32, y:F32}, local S = Sum{a:Unit, b:U32}')
parses('typed word', 'local f = do(x: U32): U32 = x + 1', 'local f = fn(x):U32=(x + 1)')
parses('opening', 'local ctx.. = e\nf do(..) g end', 'open ctx = e, f(fn(..){g()})')
parses('continue', 'for i = 1, 2 do continue end', 'for i {continue}')
parse_rejects('endall outside', 'endall', "'endall' closes no open lambda")
parse_rejects('a typed parameter without a result', 'f = do(x: U32) = x', 'declares no result type')

-- LuaJIT 3.0's syntax (design macro-layer.md L1, L2)
parses('customary operators are normalized', 'x = !a && b || c != d', 'x = (((not a) and b) or (c ~= d))')
parses('?? with or', 'x = a ?? b and c', 'x = (a ?? (b and c))')
parses('bit operators', 'x = ~a & b | c ~ d << 1 ~>> 2', 'x = (((~ a) & b) | (c ~ ((d << 1) ~>> 2)))')
parses('.. binds tighter than shifts', 'x = 1 << 2 .. s', 'x = (1 << (2 .. s))')
parses('conditional', 'x = c ? a : b', 'x = (c ? a : b)')
parses('conditional is right-associative', 'x = c ? a : d ? b : e', 'x = (c ? a : (d ? b : e))')
parses('a conditional at the end of a line is not a block colon', 'x = c ? a : b\ny = 1', 'x = (c ? a : b), y = 1')
parses('safe navigation', 'x = t?.a?.[k]?.(1)\no?.:m(2)\no:m?.(3)', 'x = t?.a?.[k]?.(1), o?.:m(2), o:m?.(3)')
parses('short functions', 'f = |a, b| -> a + b\ng = x -> x * 2\nh = || -> 7\nv = |...| -> select(1, ...)',
    'f = arrow(a b)=(a + b), g = arrow(x)=(x * 2), h = arrow()=7, v = arrow(...)=select(1, ...)')
parses('a short function block', 'f = |x| -> do return x end', 'f = arrow(x){return x}')
parses('name -> as a juxtaposed argument', 'map xs x -> x * 2', 'map(xs)(arrow(x)=(x * 2))')
parses('compound assignment', 'a += 1\nt.n ..= "x"\nb ~= 3\nc ~>>= 2', 'a += 1, t.n ..= "x", b ~= 3, c ~>>= 2')
parses('~= in an expression is not equal', 'x = a ~= b', 'x = (a ~= b)')
parses('const', 'const X = 1\nconst A, B = 1, 2\nconst function f() end', 'const X = 1, const A, B = 1, 2, const function f fn(){}')
parses('const as a name', 'local const = 5\nconst = 6', 'local const = 5, const = 6')
parses('semicolons anywhere', ';; f();; do return;; end', 'f(), do {return }')
parses('goto and labels', 'goto a\n::a::', 'goto a, ::a::')
parse_rejects('a parallel compound assignment', 'a, b += 1, 1', "'=' expected")

-- the emitter: dialect programs run as plain Lua ------------------------------------------------
local dialect = require 'dialect'
local function runs(name, src, expect)
    local chunk, err = dialect.load(src, '=' .. name)
    if not chunk then return check('runs: ' .. name, false, err) end
    local ok, got = pcall(chunk)
    check('runs: ' .. name, ok and got == expect, ok and ('got ' .. tostring(got) .. ', expected ' .. tostring(expect)) or got)
end
local function fails_at(name, src, line)
    local chunk, err = dialect.load(src, '=' .. name)
    if not chunk then return check('fails at: ' .. name, false, err) end
    local ok, e = pcall(chunk)
    check('fails at: ' .. name, not ok and tostring(e):find(':' .. line .. ':', 1, true), ok and 'ran' or e)
end

runs('juxtaposition', 'local add = do(a) = do(b) = a + b\nreturn add 1 2', 3)
runs('a string argument takes its chain', 'local id = do(x) = x\nreturn id "ab":rep 2', 'abab')
runs('block lambda', 'local function twice(f) return f() * 2 end\nreturn twice do\n  return 21\nend', 42)
runs('trailing colon', 'local function with_value(v) return function(f) return f(v) end end\nreturn with_value 20: x\n  return x + 1\nend', 21)
runs('=: assigns a block', 'local f =: x\n  return x * 3\nend\nreturn f(5)', 15)
runs('zero-argument call statement', 'local n = 0\nlocal function bump() n = n + 1 end\nbump\nbump\nreturn n', 2)
runs('with block', 'local function P(t) return t end\nlocal p = P with\n  x = 1\n  y = 2\nend\nreturn p.x + p.y', 3)
runs('field shorthand', 'local x, y = 3, 4\nlocal t = { .x, .y }\nreturn t.x * t.y', 12)
runs('keyed spread', 'local base = define { a = 1, b = 2 }\nlocal t = { ..base, b = 5 }\nreturn t.a + t.b', 6)
runs('keyed spread overlap', 'local ok = pcall(function() return { ..{ a = 1 }, ..{ a = 2 } } end)\nreturn ok', false)
runs('contextual with is a table', 'local t = with\n  k = 7\nend\nreturn t.k', 7)
runs('opening reads members', 'local ctx = { a = 10 }\nlocal f = do(..) return a + 1 end\nreturn f(ctx)', 11)
runs('opening calls members', 'local v = { double = function(x) return x * 2 end }\nlocal f = do(..) return double 4 end\nreturn f(v)', 8)
runs('opening writes members it introduces', 'local ctx = { n = 1 }\nlocal f = do(..) n = n + 1 end\nf(ctx)\nreturn ctx.n', 2)
runs('opening writes other names where Lua would', 'local ctx = {}\nlocal f = do(..) fresh_global_x = 4 end\nf(ctx)\nlocal v = fresh_global_x\nfresh_global_x = nil\nreturn v', 4)
runs('a local shadows an opening', 'local ctx = { a = 1 }\nlocal f = do(..)\n  local a = 5\n  return a\nend\nreturn f(ctx)', 5)
runs('local ctx.. opens', 'local v = { k = 9 }\nlocal ctx.. = v\nreturn k', 9)
runs('a spread of a call in an initializer', 'local function pair(x) return x, x + 1 end\nlocal a, b = ..pair 1\nreturn a + b', 3)
runs('rest parameters', 'local f = do(..args) = args.n\nreturn f(1, 2, 3)', 3)
runs('spread in a call', 'local t = { 1, 2, 3 }\nreturn select("#", print and nil, ..t)', 4)
runs('LuaJIT 3.0 forms', 'local t = nil\nlocal a = t?.x ?? 5\nlocal f = |x| -> x * 2\nlocal b = a > 3 ? f(a) : 0\nb += 1\nreturn b', 11)
runs('name -> as an argument', 'local function map(xs) return function(f) local o = {} for i, x in ipairs(xs) do o[i] = f(x) end return o end end\nlocal xs = { 1, 2 }\nlocal r = map xs x -> x * 10\nreturn r[2]', 20)
runs('customary operators', 'return !false && (1 != 2) || false', true)
runs('continue', 'local n = 0\nfor i = 1, 5 do\n  if i % 2 == 0 then continue end\n  n = n + i\nend\nreturn n', 9)
runs('endall', 'local function each(xs) return function(f) for _, x in ipairs(xs) do f(x) end end end\nlocal n = 0\neach { 1, 2 }: a\n  each { 10, 20 }: b\n    n = n + a * b\nendall\nreturn n', 90)
fails_at('a runtime error keeps its line', 'local x = 1\n\nlocal f = do(a)\n  return a.b.c\nend\nreturn f({})', 4)
fails_at('lines across a with block', 'local t = with\n  a = 1\n  b = 2\nend\nerror("here")', 5)

-- typed forms without a host (design macro-layer.md §4.6–§4.8) ---------------------------------
local function errors(name, src, expect, opts)
    local chunk, err = dialect.load(src, '=' .. name, opts)
    if not chunk then return check('errors: ' .. name, false, err) end
    local ok, e = pcall(chunk)
    check('errors: ' .. name, not ok and tostring(e):find(expect, 1, true), ok and 'ran' or e)
end
local function runs_with(name, src, expect, opts)
    local chunk, err = dialect.load(src, '=' .. name, opts)
    if not chunk then return check('runs: ' .. name, false, err) end
    local ok, got = pcall(chunk)
    check('runs: ' .. name, ok and got == expect, ok and ('got ' .. tostring(got)) or got)
end

-- contracts
runs('a typed function that keeps its contract', 'local f = do(x: Number): Number = x * 2\nreturn f(21)', 42)
errors('a parameter contract blames the caller', 'local f = do(x: Number): Number = x * 2\n\nreturn f("a")',
    "contract: parameter 'x' of f expects Number, got a string \"a\"")
errors('the caller\'s line', 'local f = do(x: Number): Number = x * 2\n\nlocal r = f("a")\nreturn r', 'line:3:')
errors('a result\'s line', 'local f = do(x: Number): String\n  local y = x\n  return y\nend\nlocal r = f(1)\nreturn r', 'line:3:')
errors('a result contract', 'local f = do(x: Number): String\n  return x + 1\nend\nreturn f(1)',
    'contract: the result of f expects String, got number 2')
errors('falling off the end', 'local f = do(x: Number): Number\n  local y = x\nend\nreturn f(1)',
    'the result of f expects Number, got nil')
runs('Unit results', 'local f = do(x: Number): Unit\n  local y = x\nend\nreturn f(1) == nil', true)
runs('Optional', 'local f = do(x: Optional(Number)): Number = x or 0\nreturn f(nil) + f(2)', 2)
errors('a typed local', 'local f = do(x: Any): Number\n  local y: Number = x\n  return y\nend\nreturn f("s")',
    "local 'y' in f expects Number")
errors('assigning a typed local', 'local f = do(): Number\n  local y: Number = 1\n  y = "two"\n  return y\nend\nreturn f()',
    "local 'y' in f expects Number")
runs('a predicate checker', 'local Even = do(v) = type(v) == "number" and v % 2 == 0\nlocal f = do(x: Even): Number = x / 2\nreturn f(8)', 4)
runs('a typed local function recurses', 'local function fact(n: Number): Number\n  if n <= 1 then return 1 end\n  return n * fact(n - 1)\nend\nreturn fact(5)', 120)
runs_with('contracts switched off', 'local f = do(x: Number): Number = x\nreturn f("unchecked")', 'unchecked', { contracts = false })
do
    local text = dialect.translate('local f = do(x: Number): Number = x', 't', { contracts = false })
    check('contracts off evaluate no annotation', not text:find('Number', 1, true), text)
end

-- structural markers
runs('required and optional', 'local Node = closed define with\n  op = "store"\n  place = required\n  what = optional\nend\nlocal n = { ..Node, place = 1 }\nreturn n.op .. n.place .. tostring(n.what)', 'store1nil')
errors('a missing required field', 'local Node = closed define { op = "s", place = required }\nlocal n = { ..Node }',
    "required: the field 'place' is not supplied")
errors('an unknown field of a closed type', 'local Node = closed define { op = "s" }\nlocal n = { ..Node, plcae = 1 }',
    "closed: 'plcae' is not a field")
errors('instances stay closed', 'local Node = closed define { op = "s" }\nlocal a = { ..Node }\nlocal b = { ..a, x = 1 }',
    "closed: 'x' is not a field")
runs('a closed type is a checker', 'local P = closed define { x = required, y = 0 }\nlocal f = do(p: P): Number = p.x + p.y\nreturn f({ x = 2, y = 3 })', 5)
errors('a closed type rejects an extra field', 'local P = closed define { x = required }\nlocal f = do(p: P): Number = p.x\nreturn f({ x = 2, z = 1 })',
    "has the undeclared field 'z'")

-- Struct
runs('a Struct', 'local Point = Struct { x: Number, y: Number }\nfunction Point:sum(): Number return self.x + self.y end\nlocal p = Point with\n  x = 1\n  y = 2\nend\nreturn p:sum()', 3)
errors('a Struct field contract', 'local Point = Struct { x: Number, y: Number }\nlocal p = Point { x = 1, y = "2" }',
    "the field 'y' of Point expects Number")
errors('an unknown Struct field', 'local Point = Struct { x: Number }\nlocal p = Point { x = 1, z = 2 }', "Point has no field 'z'")
runs('a Struct is a checker', 'local Point = Struct { x: Number }\nlocal f = do(p: Point): Number = p.x\nreturn f(Point { x = 7 })', 7)
errors('a Struct checker is nominal', 'local Point = Struct { x: Number }\nlocal f = do(p: Point): Number = p.x\nreturn f({ x = 7 })',
    'expects Point, got a table')
runs('spread with overrides builds a Struct', 'local Point = Struct { x: Number, y: Number }\nlocal p = Point { x = 1, y = 2 }\nlocal q = Point { ..p, y = 5 }\nreturn q.x + q.y', 6)

-- Sum
runs('a Sum and its match', 'local Shape = Sum { circle: Number, square: Number, none: Unit }\nlocal area = do(s) = s with\n  circle = do(r) = 3 * r * r\n  square = do(a) = a * a\n  none = do() = 0\nend\nreturn area(Shape.circle(2)) + area(Shape.square(3)) + area(Shape.none())', 21)
errors('a payload contract', 'local Shape = Sum { circle: Number }\nlocal s = Shape.circle("big")', 'the payload of Shape.circle expects Number')
errors('a missing handler', 'local Shape = Sum { a: Unit, b: Unit }\nlocal v = Shape.a()\nreturn v { a = do() = 1 }', "the alternative 'b' has no handler")
errors('an unknown handler', 'local Shape = Sum { a: Unit }\nlocal v = Shape.a()\nreturn v { a = do() = 1, c = do() = 2 }', "has no alternative 'c'")
runs('a Sum is a checker', 'local R = Sum { ok: Number, err: String }\nlocal f = do(r: R): Number = r { ok = do(v) = v, err = do(e) = -1 }\nreturn f(R.ok(4))', 4)

-- every tracked source: the round trip is exact, and every number and string token is one
-- LuaJIT reads the same way
local function sh(cmd)
    local p = assert(io.popen(cmd)); local out = p:read '*a'; p:close(); return out
end
local files = {}
for f in sh('cd ' .. root .. ' && git ls-files "*.lua" "*.nua" 2>/dev/null'):gmatch '[^\n]+' do
    files[#files + 1] = f
end
local sources, literals = 0, 0
for _, f in ipairs(files) do
    local fh = io.open(root .. '/' .. f, 'rb')
    if fh then
        local src = fh:read '*a'; fh:close()
        local ok, ts = pcall(lex.scan, src, f)
        if not ok then
            check('scans ' .. f, false, ts)
        else
            check('round trip ' .. f, lex.text(ts) == src)
            sources = sources + 1
            for _, tk in ipairs(ts) do
                if tk.t == 'number' or tk.t == 'string' then
                    literals = literals + 1
                    local chunk = loadstring('return ' .. tk.v)
                    if not chunk then check(('LuaJIT reads %s:%d %s'):format(f, tk.line, tk.v), false) end
                end
            end
        end
    end
end
check('sources were found', sources > 100, sources)

-- every tracked source parses, except these, which do not by design: fixtures of failures,
-- the old `struct` spelling kept as raw evidence, and LuaMacro's own modules (being removed)
local NOT_DIALECT = {
    ['tests/macros/fixtures/macro_error.lua'] = true, ['tests/macros/fixtures/syntax_error.lua'] = true,
    ['tests/modules/broken.nua'] = true, ['macro/lambda.lua'] = true,
}
local host = { statements = { export = function(p, tk)
    local r = p.r
    r:next()
    local n = r:name('after export')
    while r:accept('.') do r:name('after export') end
    if r:peek(1).t == 'name' and r:peek(1).v == 'as' and not r:peek(1).nl then r:next(); r:next() end
    return { k = 'export', name = n.v, line = tk.line }
end }, prefixes = { call = function(p, tk)
    local nt = p.r:peek(2)
    if nt.t == 'name' and not nt.nl then p.r:next(); local e = p:suffixed(); e.boundary = true; return e end
end } }
local parsed = 0
for _, f in ipairs(files) do
    if not NOT_DIALECT[f] and not f:match '^nua/experiments/' then
        local fh = io.open(root .. '/' .. f, 'rb')
        if fh then
            local src = fh:read '*a'; fh:close()
            local ok, e = pcall(parse.parse, src, f, f:match '%.nua$' and host or nil)
            if ok then parsed = parsed + 1 else check('parses ' .. f, false, e) end
        end
    end
end
check('sources were parsed', parsed > 100, parsed)

-- every parsed source translates to Lua that LuaJIT compiles (typed forms without the Nua host
-- are emitted with their annotations dropped; `export` gets a stub)
host.statements_emit = nil
local emit_host = { statements = { export = function(node) return '-- export ' .. node.name end } }
local compiled = 0
for _, f in ipairs(files) do
    if not NOT_DIALECT[f] and not f:match '^nua/experiments/' then
        local fh = io.open(root .. '/' .. f, 'rb')
        if fh then
            local src = fh:read '*a'; fh:close()
            local ok, text = pcall(function()
                local block = parse.parse(src, f, f:match '%.nua$' and host or nil)
                return require('dialect.emit').emit(block, { filename = f, host = emit_host })
            end)
            if not ok then check('translates ' .. f, false, text)
            else
                local chunk, err = loadstring(text, '@' .. f)
                if chunk then compiled = compiled + 1 else check('LuaJIT compiles ' .. f, false, err) end
            end
        end
    end
end
check('sources were compiled', compiled == parsed, compiled .. ' of ' .. parsed)

print(('dialect: %d passed, %d failed (%d sources round-tripped, %d literals cross-checked, %d parsed, %d compiled)'):format(
    passed, failed, sources, literals, parsed, compiled))
os.exit(failed == 0 and 0 or 1)
