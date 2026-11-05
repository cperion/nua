-- The trailing colon: a colon that ends a line is `do(..)`. A block with parameters, an
-- assigned block and a returned block are do lambdas. Annotation colons never change.
local root = arg[0]:match('^(.*)/tests/[^/]*$') or '.'
package.path = root .. '/?.lua;' .. package.path
package.path = root .. '/?/init.lua;' .. package.path
-- sources translate through Mua with the Nua host (design macro-layer.md step 3)
local mua = require 'mua.init'
local front = require 'nua.front'
local dlex = require 'mua.lex'
local colon = require 'mua.fmt_text'
local fmt = require 'nua.fmt'
local passed = 0
local function check(name, condition, detail)
    assert(condition, name .. (detail and ('\n' .. detail) or ''))
    passed = passed + 1
end
local function normal(code)
    local parts = {}
    -- the runtime binding the emitter puts on the first line is not part of the program
    code = code:gsub('^local __mua = __mua or require%("mua%.runtime"%); ', '')
    for _, tk in ipairs(dlex.scan(code, 'normal')) do
        if tk.t ~= 'space' and tk.t ~= 'comment' then parts[#parts + 1] = tk.v end
    end
    return table.concat(parts, '\0')
end
local function translated(source, name)
    return mua.translate(source, name, { host = front.host(name) })
end

-- the bare trailing colon translates exactly as the do-form it stands for
local pairs_of = {
    { 'anonymous', 'with_buffer n:\n    go\nend\n', 'with_buffer n do(..)\n    go\nend\n' },
    { 'after a call', 'view_of(p, n):\n    go\nend\n', 'view_of(p, n) do(..)\n    go\nend\n' },
    { 'trailing comment', 'xs:each: -- note\n    go\nend\n', 'xs:each do(..) -- note\n    go\nend\n' },
    { 'in an initializer', 'local total = view_of(p, n):\n    go\nend\n',
      'local total = view_of(p, n) do(..)\n    go\nend\n' },
    { 'nested', 'a:\n    b:\n        go\n    end\nend\n', 'a do(..)\n    b do(..)\n        go\n    end\nend\n' },
}
for _, case in ipairs(pairs_of) do
    check('colon block: ' .. case[1], normal(translated(case[2], case[1]))
        == normal(translated(case[3], case[1])), translated(case[2], case[1]))
end

-- the removed spellings are parse errors that say what to write
local rejected = {
    { 'colon parameters', 'xs:each: k v\n    go\nend\n',
      "a block colon takes no parameters; write 'do(k, v) ... end' after the call" },
    { 'a named opening', 'tasks: scope..\n    go\nend\n',
      "a block colon takes no parameters; write 'do(scope..) ... end' after the call" },
    { 'an assigned block', 'local f =: x\n    go x\nend\n',
      "an assigned block is written '= do(x) ... end', not '=:'" },
    { 'an assigned block opening the home', 'g.h =:\n    go\nend\n',
      "an assigned block is written '= do(..) ... end', not '=:'" },
    { 'a returned block', 'return: b\n    go\nend\n',
      "a returned block is written 'return do(b) ... end', not 'return:'" },
}
for _, case in ipairs(rejected) do
    local ok, err = pcall(translated, case[2], case[1])
    check('rejects ' .. case[1], not ok and tostring(err):find(case[3], 1, true), ok and 'translated' or err)
end

-- `with` blocks are table constructors without commas
local with_pairs = {
    { 'with block', 'local p = Point with\n    x = 1\n    y = 2\nend\n', 'local p = Point {\n    x = 1,\n    y = 2\n}\n' },
    { 'with on one line', 'local p = Point with x = 1 y = 2 end\n', 'local p = Point { x = 1, y = 2 }\n' },
    { 'shorthand entries', 'local p = Point with\n    .x\n    .y\nend\n', 'local p = Point {\n    .x,\n    .y\n}\n' },
    { 'struct', 'local P = struct\n    x: F32\n    y: F32\nend\n', 'local P = struct {\n    x: F32,\n    y: F32\n}\n' },
    { 'continued entry', 'local p = T with\n    x = a +\n        b\n    y = 2\nend\n', 'local p = T {\n    x = a +\n        b,\n    y = 2\n}\n' },
    { 'handlers', 'local r = s with\n    a = do(v)\n        go v\n    end\n    b = do(x) = x\nend\n',
      'local r = s {\n    a = do(v)\n        go v\n    end,\n    b = do(x) = x\n}\n' },
    { 'nested', 'local p = T with\n    inner = U with k = 1 end\n    z = 3\nend\n', 'local p = T {\n    inner = U { k = 1 },\n    z = 3\n}\n' },
    { 'as an argument', 'f x with k = 1 end\n', 'f x { k = 1 }\n' },
    { 'commas still allowed', 'local p = T with x = 1, y = 2 end\n', 'local p = T { x = 1, y = 2 }\n' },
    { 'inside a loop and a function', 'local p = T with\n    f = function() return 1 end\n    g = 2\nend\nfor i = 1, 2 do\n    local q = T with k = i end\nend\n',
      'local p = T {\n    f = function() return 1 end,\n    g = 2\n}\nfor i = 1, 2 do\n    local q = T { k = i }\nend\n' },
}
for _, case in ipairs(with_pairs) do
    check('with block: ' .. case[1], normal(translated(case[2], case[1])) == normal(translated(case[3], case[1])),
        translated(case[2], case[1]))
end
local ordinary = [[
local with = 3
local x = with + 1
local t = { with = 5 }
assert(x == 4 and t.with == 5)
]]
assert(loadstring(translated(ordinary, 'ordinary.nua'), '@ordinary.nua'))()
check('with is an ordinary name elsewhere', true)

-- `with` where an expression starts takes its type from the context: it is the runtime's
-- `with` applied to the entries (Nua's prelude binds it to the contextual constructor)
local contextual = {
    { 'return with', 'return with\n    x = 1\nend\n', 'return __mua.with {\n    x = 1\n}\n' },
    { 'typed local', 'local p: Point = with x = 1, y = 2 end\n', 'local p: Point = __mua.with { x = 1, y = 2 }\n' },
    { 'argument', 'f(with x = 1 end)\n', 'f(__mua.with { x = 1 })\n' },
    { 'field value', 'local p = T with\n    left = with x = 1 end\nend\n', 'local p = T {\n    left = __mua.with { x = 1 }\n}\n' },
}
for _, case in ipairs(contextual) do
    check('contextual with: ' .. case[1], normal(translated(case[2], case[1])) == normal(translated(case[3], case[1])),
        translated(case[2], case[1]))
end
local variable = [[
local with = 3
local t = { with = 5 }
assert(with + t.with == 8)
local function pass(with) return with end
assert(pass(4) == 4)
]]
assert(loadstring(translated(variable, 'variable.nua'), '@variable.nua'))()
check('a variable named with is still a variable', true)
check('an unclosed with block is an error', not pcall(translated, 'local p = T with x = 1\n', 'open'))

-- `endall` closes every open Nua block (colon, do and with) back to Lua control
local endall_pairs = {
    { 'a chain of data and handlers',
      'a with\n    y = do(v)\n        b with\n            z = do(w)\n                go w\nendall\nafter()\n',
      'a with\n    y = do(v)\n        b with\n            z = do(w)\n                go w\n            end\n        end\n    end\nend\nafter()\n' },
    { 'it stops at a Lua block',
      'x:\n    if c then\n        y:\n            go\n        endall\n    end\nend\n',
      'x:\n    if c then\n        y:\n            go\n        end\n    end\nend\n' },
}
for _, case in ipairs(endall_pairs) do
    check('endall: ' .. case[1], normal(translated(case[2], case[1])) == normal(translated(case[3], case[1])),
        translated(case[2], case[1]))
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
    { 'struct field', 'local P = struct { x: U32 }\n' },
}
for _, case in ipairs(unchanged) do
    check('not a block: ' .. case[1], colon.expand(case[2]) == case[2])
end

-- line numbers survive the rewrite
local located = translated('local n = 0\nxs:each:\n    n = n + 1\nend\nlocal bad = nope.nope\n', 'lines.nua')
check('line numbers stay put', select(2, located:gsub('\n', '\n')) == 5, located)

-- a colon block runs
local host = [[
local run = do(body)
    body()
end
local total = 0
run:
    total = 6
end
assert(total == 6)
local twice = do(body) = body() * 2
local value = twice:
    return 25
end
assert(value == 50)
]]
-- a bare colon block opens its home in Mua; Nua's staging gives that home meaning
assert(loadstring(mua.translate(host, 'host.mua'), '@host.mua'))()
check('colon blocks run', true)

-- the formatter prints the colon form for untyped trailing blocks, and only there
local function formatted(name, source, expected, options)
    -- these cases pin how `with` is written; inline_with has its own cases in tests/formatter.lua
    options = options or {}
    if options.inline_with == nil then options.inline_with = 0 end
    local out = fmt.format(source, options, name)
    check(name, out == expected, out)
    check(name .. ': idempotent', fmt.format(out, options, name) == out)
end
formatted('fmt: do-form becomes colon', 'with_buffer n do(..)\n    go\nend\n', 'with_buffer n:\n    go\nend\n')
formatted('fmt: parameters stay a do-form', 'xs:each do(key, value)\n    go\nend\n', 'xs:each do(key, value)\n    go\nend\n')
formatted('fmt: an opened name stays a do-form', 'tasks do(scope..)\n    use scope\nend\n', 'tasks do(scope..)\n    use scope\nend\n')
formatted('fmt: an assigned block stays a do-form', 'local t = {\n    found = do(v)\n        go v\n    end,\n}\n',
    'local t = {\n    found = do(v)\n        go v\n    end,\n}\n')
formatted('fmt: an assigned block opens the home', 'local f = do(..)\n    go\nend\n', 'local f = do(..)\n    go\nend\n')
formatted('fmt: expression lambda untouched', 'local f = do(x) = x + 1\n', 'local f = do(x) = x + 1\n')
formatted('fmt: colon form kept', 'xs:each:\n    go\nend\n', 'xs:each:\n    go\nend\n')
formatted('fmt: typed lambda untouched', 'local f = do(a: U32): U32\n    return a\nend\n',
    'local f = do(a: U32): U32\n    return a\nend\n')
formatted('fmt: inline block untouched', 'xs:each do(x) go x end\n', 'xs:each do(x) go x end\n')
formatted('fmt: nullary block untouched', 'spawn do\n    go\nend\n', 'spawn do\n    go\nend\n')
formatted('fmt: block style do', 'xs:each:\n    go\nend\n', 'xs:each do(..)\n    go\nend\n',
    { block_style = 'do' })
formatted('fmt: with block kept', 'local p = Point with\nx = 1\ny = 2\nend\n', 'local p = Point with\n    x = 1\n    y = 2\nend\n')
formatted('fmt: with on one line keeps commas', 'local p = Point   with x=1   y=2 end\n', 'local p = Point with x = 1, y = 2 end\n')
formatted('fmt: braces stay braces', 'local p = Point { x = 1, y = 2 }\n', 'local p = Point { x = 1, y = 2 }\n')
formatted('fmt: with commas on one line stay', 'local p = Point with x = 1, y = 2 end\n', 'local p = Point with x = 1, y = 2 end\n')
formatted('fmt: with and a block entry', 'local r = s with\n  a = do(v)\n    local x, y = v, v\n    go x y\n  end\n  b = 2\nend\n',
    'local r = s with\n    a = do(v)\n        local x, y = v, v\n        go x y\n    end\n    b = 2\nend\n')
formatted('fmt: struct', 'local P = struct\nx: F32\ny: F32\nend\n', 'local P = struct\n    x: F32\n    y: F32\nend\n')
formatted('fmt: positional entries keep commas', 'local a = Array(U32, 2) with 1, 2 end\n', 'local a = Array(U32, 2) with 1, 2 end\n')
formatted('fmt: multi-line table after a head becomes with', 'local q = Point {\n    x = 1,\n    y = 2,\n}\n',
    'local q = Point with\n    x = 1\n    y = 2\nend\n')
formatted('fmt: head-less tables stay braces', 'local t = {\n    a = 1,\n    b = 2,\n}\n', 'local t = {\n    a = 1,\n    b = 2,\n}\n')
formatted('fmt: one-line tables stay braces', 'local q = Point { x = 1, y = 2 }\n', 'local q = Point { x = 1, y = 2 }\n')
formatted('fmt: handlers become with', 'local r = s {\n    a = do(v)\n        go v\n    end,\n    b = do(x) = x,\n}\n',
    'local r = s with\n    a = do(v)\n        go v\n    end\n    b = do(x) = x\nend\n')
formatted('fmt: positional entries keep their commas', 'local a = Array(U32, 2) {\n    1,\n    [3] = 2,\n}\n',
    'local a = Array(U32, 2) with\n    1,\n    [3] = 2\nend\n')
formatted('fmt: nested tables convert one by one', 'local p = T {\n    inner = U {\n        k = 1,\n    },\n    z = {1, 2},\n}\n',
    'local p = T with\n    inner = U with\n        k = 1\n    end\n    z = { 1, 2 }\nend\n')
formatted('fmt: data style preserve', 'local q = Point {\n    x = 1,\n    y = 2,\n}\n', 'local q = Point {\n    x = 1,\n    y = 2,\n}\n',
    { data_style = 'preserve' })
formatted('fmt: lists of values stay braces', 'local names = ipairs {\n    "x",\n    "y",\n}\n', 'local names = ipairs {\n    "x",\n    "y",\n}\n')
formatted('fmt: a loop header keeps its braces', 'for _, n in ipairs {\n    a = 1,\n    b = 2,\n} do\n    go n\nend\n',
    'for _, n in ipairs {\n    a = 1,\n    b = 2,\n} do\n    go n\nend\n')
formatted('fmt: a table wrapped by width puts every entry on its own line, end on its own line',
    'local c = App {\n    counter = Counter { count = Number { x = 20, y = 20, width = 208, height = 24, color = 66051, value = 7 }, up = Button { x = 20, y = 60, width = 100, height = 30 } },\n}\n',
    'local c = App with\n    counter = Counter with\n        count = Number with\n            x = 20\n            y = 20\n            width = 208\n            height = 24\n            color = 66051\n            value = 7\n        end\n        up = Button { x = 20, y = 60, width = 100, height = 30 }\n    end\nend\n')
formatted('fmt: a short table stays braces inside a with', 'local c = App {\n    counter = Counter { count = 1, up = 2 },\n}\n',
    'local c = App with\n    counter = Counter { count = 1, up = 2 }\nend\n')
formatted('fmt: contextual with kept', 'return with\nx = 1\nend\n', 'return with\n    x = 1\nend\n')
formatted('fmt: contextual with on one line', 'local p: Point = with x = 1, y = 2 end\n', 'local p: Point = with x = 1, y = 2 end\n')
-- trailing runs of `end` that close Nua blocks fold into one `endall`, flat: the wrappers,
-- then the content indented once, the handler chain flat, siblings and the body one level in
local pyramid = 'local f = do(n: U32): U32\n    tasks:\n        spawn:\n            io.listen(0) with\n                failed = do(e) end\n                done = do(l)\n                    io.accept(l) with\n                        failed = do(e) end\n                        done = do(c)\n                            go c\n                        end\n                    end\n                end\n            end\n        end\n    end\n    return n\nend\n'
local folded = 'local f = do(n: U32): U32\n    tasks:\n    spawn:\n        io.listen 0 with\n            failed = do(e) end\n        done = do(l)\n        io.accept(l) with\n            failed = do(e) end\n        done = do(c)\n            go c\n    endall\n    return n\nend\n'
formatted('fmt: a pyramid of handlers folds into endall', pyramid, folded)
formatted('fmt: a folded chain stays folded', folded, folded)
formatted('fmt: a short chain keeps its ends', 'a with\n    x = do end\n    y = do(v)\n        go v\n    end\nend\n',
    'a with\n    x = do end\n    y = do(v)\n        go v\n    end\nend\n')
-- spine_style none keeps the staircase: the handlers' ends stay (the lambda wrappers still fold)
formatted('fmt: spine_style none keeps the staircase', pyramid,
    'local f = do(n: U32): U32\n    tasks:\n        spawn:\n            io.listen 0 with\n                failed = do(e) end\n                done = do(l)\n                    io.accept(l) with\n                        failed = do(e) end\n                        done = do(c)\n                            go c\n                        end\n                    end\n                end\n            end\n        endall\n    return n\nend\n',
    { spine_style = 'none' })
check('fmt: bad data style', not pcall(fmt.format, 'x = 1\n', { data_style = 'pretty' }))
check('fmt: bad block style', not pcall(fmt.format, 'x = 1\n', { block_style = 'ruby' }))

print(('%d trailing colon checks passed'):format(passed))
