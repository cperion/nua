-- File and configuration handling for nua fmt: Mua's command with Nua's formatter host and
-- `.nuafmt.lua`.
local M = {}
function M.run(args)
    return require('mua.fmt_cli').run(args, { host = require('nua.fmt').host, command = 'luajit nua.lua fmt',
        config_name = '.nuafmt.lua' })
end
return M
