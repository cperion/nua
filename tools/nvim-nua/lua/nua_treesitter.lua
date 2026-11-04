-- GPL-3.0-or-later. See ../../../COPYING.
-- Nua's editor support is Mua's: the parser is Mua's grammar, and Nua only registers its own
-- language over that parser library, with highlight queries for what Nua adds (queries/nua).
local M = {}

function M.setup(opts)
  opts = opts or {}
  local source = debug.getinfo(1, 'S').source:sub(2)
  local runtime = vim.fn.fnamemodify(source, ':p:h:h')
  local root = vim.fn.fnamemodify(runtime, ':h:h')
  -- the Mua checkout `make mua` fetched (or one you name), which has the plugin and the parser
  local mua = opts.mua or (root .. '/build/deps/src/mua')
  vim.opt.runtimepath:prepend(mua .. '/tools/tree-sitter-mua')
  local mua_ts = require('mua_treesitter')
  mua_ts.setup({ parser = opts.parser, extension = false })
  vim.opt.runtimepath:prepend(runtime)
  mua_ts.add_language('nua', { extension = 'nua' })
end

return M
