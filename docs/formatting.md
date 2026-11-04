# Formatting Nua

`nua fmt` is Mua's formatter ([`docs/formatting.md`](https://github.com/cperion/mua/blob/master/docs/formatting.md)
in the Mua repository; the checkout `make mua` fetches has it under `build/deps/src/mua/docs/`)
with Nua's host. Mua parses and lays out: the trailing colon, `with` blocks, `endall` spines,
call spelling, opening and table style, the settings below, and the guarantee that the parsed
program is unchanged. Nua adds what only Nua knows: the `export` and `call` forms, the facts
that say which callees are words (`nua/application.lua`), the exports of the Nua modules a file
requires, and one setting and pass, `type_style`. It does not execute the source or resolve
imports.

## Commands

```sh
luajit nua.lua fmt program.nua                  # formatted source on stdout
luajit nua.lua fmt -                            # stdin to stdout (also the default)
luajit nua.lua fmt --check examples/*.nua        # CI: report files needing formatting
luajit nua.lua fmt --write program.nua lib/*.nua # explicitly update these files
luajit nua.lua fmt --config path/to/style.lua program.nua
```

Options, exit statuses and the write-preflight rule are Mua's. The configuration file is the
nearest `.nuafmt.lua`, searched upward from each input.

## Settings

Mua's settings (`indent_width`, `column_width`, `call_style`, `spine_style`, `table_style`,
`spread_style`, `opening_style`, `block_style`, `data_style`, `inline_with`, `lambda_style`) and Nua's.
Nua sets `lambda_style = "do"` by default: an arrow lambda is not accepted in a typed body yet.

```lua
-- .nuafmt.lua
return {
    type_style = "inferred",   -- the default; "preserve" keeps every annotation
}
```

| Setting | Values | Meaning |
|---|---|---|
| `type_style` | `"inferred"`, `"preserve"` | Drop a local's annotation when its initializer is an application of that same type (below), or keep every annotation. |

Unknown settings and invalid values are errors, not silently ignored options.

## Inferred types

A native local takes its type from its initializer (syntax §5.1), so
`local p: Point = Point { x = 1 }` repeats itself. With `type_style = "inferred"`
the annotation is removed when the initializer is exactly an application of the
annotated type expression:

```lua
local p: Point = Point { x = 1 }          -- local p = Point { x = 1 }
local count: U32 = U32(0)                 -- local count = U32 0
local out: Grow U32 = (Grow U32) {}       -- local out = (Grow U32) {}
```

It is also removed when the initializer is a name whose declared type is the same
bare type name: a typed parameter, an earlier annotated local, a numeric `for`
variable, or a local initialized by a constructor. The name must resolve to that
declaration (scopes and shadowing are followed), and `Str` and `Text` are never
dropped.

```lua
local f = do(n: U32): U32
    local i: U32 = n                      -- local i = n
    local j: U32 = i                      -- local j = i
    return j
end
```

The formatter never evaluates the program, so it decides only what the syntax
shows. These keep their annotation: `local w: U64 = n` (a different type),
`local j: U32 = r` with `r: Ref U32` (a reference keeps write-through),
`local k: U64 = U64(n) + 1` (an expression, not the constructor itself),
`local z: U32 = 0` (a host number), `local q: U8 = U32 0` (a different type),
a name it cannot resolve to a typed declaration, and `for i: U32 = 1, n`. The rewrite is applied only when the reparsed program equals
the original with exactly those annotations removed.


## Compiler-informed word applications

In typed bodies, minimal style also rewrites `add(x, y)` to `add x y` when the
callee is provably a Nua word. This uses the same non-executing application
analysis as staged code generation ([application.lua](<../nua/application.lua>)), rather than assuming
that every callable follows word saturation:

```lua
local add = do(a: U32, b: U32): U32 = a + b
local plus = add
local run = do(x: U32, y: U32): U32
    return plus(x, y)                     -- return plus x y
end
```

The facts come from the whole file without running it: local typed lambdas and
functions, immutable aliases, provably unsaturated partial applications, the
prelude's declared arities (`band`, `shl`, …), `extern` declarations with a
literal parameter list, and the words an imported Nua module exports
(`local stacks = require "nua.stacks"` makes `stacks.span(s, at, n)` a word
call). Modules are found the way compilation finds them and are parsed, never
executed; a Lua module on the path stays unknown. Scopes, shadowing, opened
contexts and later writes invalidate a fact; method callees remain unknown.

A word gets every group as one supply; a function with a declared arity takes
groups up to that arity, so only calls within it are regrouped. Host call sites
keep their multi-argument groups.


## Checks and embedding

```sh
make test-format
```

The tests cover Nua's half: golden output with typed words, `call` boundaries, the inferred
types, word applications with their facts, and the compile-equivalence check, which formats every
example and library twice and compares generated C before and after formatting (ignoring
diagnostic source-line changes). Mua's own formatter tests run in the Mua repository
(`make test-mua`).

From Lua:

```lua
local fmt = require 'nua.fmt'
local formatted = fmt.format(source, { indent_width = 2 }, "program.nua")
```

The library returns formatted text or raises an error. It does not search for configuration
files or read/write source files; that is the command's responsibility.
