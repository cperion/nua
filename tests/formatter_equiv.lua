-- Worker for tests/formatter.lua: does the formatted program compile to the same C as the
-- original (compile-time assertions included)? Prints `equivalent`, or what differs.
local root = arg[0]:match('^(.*)/tests/[^/]*$') or '.'
package.path = root .. '/?.lua;' .. root .. '/?/init.lua;' .. package.path
local fmt = require 'nua.fmt'
package.loaded['nua.driver_loaded'] = true
local nua = dofile(root .. '/nua.lua')
local name = arg[1]
local h = assert(io.open(name, 'rb')); local source = h:read('*a'); h:close()
local function normalized(c) return (c:gsub('([%w_./%-]+%.nua):%d+:', '%1:<line>:')) end
local result = fmt.format(source, nil, name)
local before, after = normalized(nua.compile(source, name)), normalized(nua.compile(result, name))
print(before == after and 'equivalent' or (name .. ': the formatted program compiles to different C'))
