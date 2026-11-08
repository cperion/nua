-- The test runner of the replacement compiler. next/ is self-contained: its modules are Mua
-- files under next/, found by Mua's searcher; nothing is required from the current compiler
-- in nua/. Mua emits LuaJIT 3.0 syntax verbatim, so it needs upstream LuaJIT, the one
-- `make deps` installs in .local/bin. From the repository root:
--
--   make test-next                                   every next/tests/*.mua
--   .local/bin/luajit next/test.lua graph            only next/tests/graph.mua
--   .local/bin/luajit next/test.lua --match borrow   only cases whose name contains "borrow"
--
-- A test file names its cases with Mua's `test "what it shows":` word; Mua's test runner
-- collects and runs them (mua/test_cli.lua).
local here = arg[0]:match('^(.*)/[^/]*$') or '.'
local root = here .. '/..'
package.path = root .. '/.local/share/lua/5.1/?.lua;' .. root .. '/.local/share/lua/5.1/?/init.lua'
package.cpath = root .. '/.local/lib/lua/5.1/?.so'

local mua = require 'mua'
-- only Mua modules under next/ and Mua itself: a stray require of the old compiler fails
table.insert(package.loaders, 2, mua.searcher { path = here .. '/?.mua;' .. here .. '/?/init.mua' })

local only, match = nil, nil
local i = 1
while arg[i] do
    if arg[i] == '--match' then
        match = arg[i + 1]
        i = i + 1
    else
        only = arg[i]
    end
    i = i + 1
end

local files = {}
for file in io.popen('ls ' .. here .. '/tests/*.mua 2>/dev/null'):lines() do
    local name = file:match('([^/]*)%.mua$')
    if not only or name == only then files[#files + 1] = file end
end

local _, failed = require('mua.test_cli').run_files(files, { match = match })
os.exit(failed == 0 and 0 or 1)
