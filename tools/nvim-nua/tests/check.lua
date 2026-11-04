-- Run from the Nua repository root with Neovim 0.10+, after `make mua` and Mua's `make tree-sitter`
-- (make test-tree-sitter does both). Nua's editor support is Mua's parser plus queries.
local root = vim.fn.getcwd()
local mua = os.getenv('MUA_CHECKOUT') or (root .. '/build/deps/src/mua')
vim.opt.runtimepath:prepend(root .. '/tools/nvim-nua')
require('nua_treesitter').setup({ mua = mua, parser = mua .. '/build/tree-sitter-mua/mua.so' })
vim.cmd('filetype on')
local query = assert(vim.treesitter.query.get('nua', 'highlights'))
local count = 0
local function read(path) return table.concat(vim.fn.readfile(path), '\n') .. '\n' end
for _, pattern in ipairs({ 'examples/*.nua', 'lib/*.nua', 'tools/nvim-nua/tests/*.nua' }) do
  for _, path in ipairs(vim.fn.glob(pattern, false, true)) do
    local tree = vim.treesitter.get_string_parser(read(path), 'nua'):parse()[1]
    assert(not tree:root():has_error(), path .. ': ' .. tree:root():sexpr())
    count = count + 1
  end
end
local fixture = root .. '/tools/nvim-nua/tests/highlights.nua'
vim.cmd.edit(vim.fn.fnameescape(fixture))
assert(vim.bo.filetype == 'nua', '*.nua filetype detection failed')
assert(vim.treesitter.highlighter.active[vim.api.nvim_get_current_buf()], 'highlighter did not start')
local tree = vim.treesitter.get_parser(0, 'nua'):parse()[1]
local captured = {}
for id, node in query:iter_captures(tree:root(), 0) do
  captured[query.captures[id] .. ':' .. vim.treesitter.get_node_text(node, 0)] = true
end
for _, pair in ipairs({
  {'keyword', 'export'}, {'keyword.function', 'do'}, {'keyword.function', 'endall'},
  {'type.builtin', 'U32'}, {'type.builtin', 'Str'}, {'variable.parameter', 'x'},
  {'function', 'inc'}, {'function.call', 'print'}, {'keyword', 'struct'},
}) do
  assert(captured[pair[1] .. ':' .. pair[2]], 'missing capture ' .. table.concat(pair, ':'))
end
print(('Nua Tree-sitter: %d files parse with Mua\'s grammar; Nua highlight captures and the nua filetype pass'):format(count))
