-- The test runner of the replacement compiler. next/ is self-contained: its modules are Mua
-- files under next/, found by Mua's searcher; nothing is required from the current compiler
-- in nua/. Mua emits LuaJIT 3.0 syntax verbatim, so it needs upstream LuaJIT, the one
-- `make deps` installs in .local/bin. From the repository root:
--
--   make test-next                          every next/tests/*.mua
--   .local/bin/luajit next/test.lua graph   only next/tests/graph.mua
--
-- Each test file returns a list of { name, run } cases; a case passes when `run` returns
-- without an error.
local here = arg[0]:match('^(.*)/[^/]*$') or '.'
local root = here .. '/..'
package.path = root .. '/.local/share/lua/5.1/?.lua;' .. root .. '/.local/share/lua/5.1/?/init.lua'
package.cpath = root .. '/.local/lib/lua/5.1/?.so'

local mua = require 'mua'
-- only Mua modules under next/ and Mua itself: a stray require of the old compiler fails
table.insert(package.loaders, 2, mua.searcher { path = here .. '/?.mua;' .. here .. '/?/init.mua' })

local only = arg[1]
local files = {}
for file in io.popen('ls ' .. here .. '/tests/*.mua 2>/dev/null'):lines() do
    local name = file:match('([^/]*)%.mua$')
    if not only or name == only then files[#files + 1] = { name = name, path = file } end
end

local passed, failed = 0, 0
for _, file in ipairs(files) do
    local chunk, problem = mua.loadfile(file.path)
    if not chunk then
        failed = failed + 1
        print(('FAIL %s: does not load: %s'):format(file.name, problem))
    else
        local loaded, cases = pcall(chunk)
        if not loaded then
            failed = failed + 1
            print(('FAIL %s: %s'):format(file.name, tostring(cases)))
        else
            for _, case in ipairs(cases) do
                local ok, why = xpcall(case.run, debug.traceback)
                if ok then
                    passed = passed + 1
                else
                    failed = failed + 1
                    print(('FAIL %s: %s\n%s'):format(file.name, case.name, why))
                end
            end
        end
    end
end
print(('%d passed, %d failed'):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
