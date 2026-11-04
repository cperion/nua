# Nua highlighting for Neovim

Nua's editor support is Mua's. The grammar, scanner, base queries and plugin live in the Mua
repository (`tools/tree-sitter-mua`); Nua is another way to run Mua code, so it carries no
grammar of its own. This directory adds what only Nua has: the `nua` language over Mua's parser
library, the `*.nua` filetype, and queries for `export`, `call` and Nua's native types
(`queries/nua/highlights.scm`, which starts with `; inherits: mua`).

## Build and check

```sh
make mua            # fetch and install the pinned Mua (once)
make tree-sitter    # builds Mua's parser in the fetched checkout
make test-tree-sitter
```

`make test-tree-sitter` parses every example and library `.nua` file with Mua's grammar and
checks Nua's highlight captures and filetype in headless Neovim. The Tree-sitter CLI is a
requirement (override with `TREE_SITTER=...`).

## Neovim setup

```lua
local nua = vim.fn.expand('~/dev/nua')
vim.opt.runtimepath:prepend(nua .. '/tools/nvim-nua')
require('nua_treesitter').setup()                  -- uses the Mua checkout under build/deps/src/mua
require('nua_treesitter').setup({ mua = vim.fn.expand('~/dev/mua') })   -- or name a checkout
```

Open a `*.nua` file: the filetype is `nua` and highlighting starts. GPL-3.0-or-later (`COPYING`).
