# Nua — staged Lua → C

Lua for program construction; typed native words, online partial evaluation and
Goose-style memory for the work that remains. Emit readable C or compile the same
prepared residual program in process with libgccjit.

```lua
local affine = do(a: U32, b: U32, x: U32): U32 = a * x + b
local transform = affine(4, 3)
assert(host(affine(4, 3, 10)) == 43)
local entry = do(x: U32): U32 = transform x * 2
export entry
```

```c
uint32_t entry(uint32_t x) {
    return (4u * x + 3u) * 2u;
}
```

Start with [Designing and writing Nua](docs/designing-and-writing-nua.md): the
design process, how to write words, and the house style. [The syntax](docs/syntax.md)
owns what a program means — the surface forms, the static rules and the runtime
contracts, including [maps](docs/syntax.md#15-maps-and-known-lookup-descriptions) and
[library-defined types](docs/syntax.md#16-library-defined-types).
[The architecture](docs/architecture.md) owns how they are implemented: the pipeline,
the residual IR, the two backends, the runtime, and
[the boundary between Nua, Lua and C](docs/architecture.md#15-what-stays-in-c-and-lua-and-why).
[Code size and compile time](docs/designing-and-writing-nua.md#112-code-size-and-compile-time)
covers `call` and `nua size`; [status and remaining work](docs/architecture.md#17-status-limits-and-remaining-work)
says what is not implemented.

## Build

On 64-bit Linux, build the pinned core dependencies and Nua without installing
system packages:

```sh
make bootstrap                    # explicit network fetch, local dependencies, dist
make doctor
make test-build
make test
make test-native
make test-dist
```

Source pins live in [the dependency lock](tools/deps.lock), not Git submodules:
this keeps repository changes native to jj. GCC 15.2.0 (including libgccjit),
LuaJIT, LPeg, and GCC's GMP/MPFR/MPC prerequisites build under ignored `build/deps/`
and install under `.local/`. No dependency source or binary is committed.
The completed local toolchain is selected by Make; incomplete or stale installs
fail rather than silently selecting host libraries. `LOCAL_DEPS=0` selects the host
setup below. See [building Nua](docs/building.md) for host prerequisites, offline
builds, pin updates, and the distinction between a local build and a portable package.

### Host dependencies (alternative)

- LuaJIT and LPeg built for **Lua 5.1**, not another Lua ABI. `make dist` also
  needs the LuaJIT development files (`lua.h`) and `libluajit-5.1`.
- A C99 compiler and POSIX threads for the native runtime/harnesses.
- libgccjit **13+**, on a 64-bit target, for JIT/native loading (optional for C output).
- GNU make and `timeout` for the convenience/check targets. Some packaged checks
  additionally use Clang/ThreadSanitizer or optional platform I/O facilities.

If LPeg is not installed for LuaJIT:

```sh
luarocks --lua-version=5.1 install lpeg
```

`make` discovers LuaRocks' Lua 5.1 C path. For direct LuaJIT commands, use
`luarocks --lua-version=5.1 path` or set `LUA_CPATH` yourself, retaining `;;` for
LuaJIT's defaults. An LPeg module built for Lua 5.4 is not interchangeable.

```sh
make doctor
make test
make test-native                 # requires libgccjit; not an optional skip
make run PROGRAM=examples/csv.nua ARGS='examples/data/sales.csv price'
```

The development targets default to two task workers; override with `NUA_WORKERS=N`.
Generated files, logs and caches go under ignored `build/`. In host mode, a local
libgccjit copy may be placed at `.local/lib/libgccjit.so.0`; Make selects it if
`NUA_GCCJIT` is unset. Otherwise install the platform's libgccjit package or set
`NUA_GCCJIT` explicitly. No compiler binary or machine-specific dependency is committed.

## Formatting

```sh
luajit nua.lua fmt program.nua          # stdout; does not modify the source
luajit nua.lua fmt --write program.nua  # explicitly update files
luajit nua.lua fmt --check examples/*.nua
```

Defaults favor four-space indentation, a soft 100-column width, safe
parenthesis-free calls, inferred local types, `.name` field shorthand and flat
endall spines. A `.nuafmt.lua` can set `indent_width`, `column_width`,
`call_style` (`"minimal"` or `"preserve"`), `type_style` (`"inferred"` or
`"preserve"`), `table_style` (`"shorthand"` or `"preserve"`) and `spine_style`
(`"pure"`, `"all"` or `"none"`). See
[formatting](docs/formatting.md) for semantics, configuration discovery and exit
codes. `make test-format` checks style, idempotence, source preservation and
compiler-output equivalence.

## Modules

```lua
local hash = require "nua.hash" -- bundled Nua vocabulary
local ffi = require "ffi"      -- ordinary Lua module
local model = require "model"  -- project Lua or Nua module
```

This is Lua's actual `require`, extended with a Nua source searcher. Bundled
names use `nua.*`, so Lua's `require "io"` still means Lua I/O. Newly loaded
modules are cached per compilation, including Lua wrappers around staged
values; host loader state is restored afterwards. See [module loading](docs/architecture.md#13-modules-and-the-compilation-scope).
Run `make test-modules` for the loader/cache contract checks.

## Neovim syntax highlighting

Nua has a dedicated Tree-sitter grammar and highlight queries. Build the local
parser with `make tree-sitter`, then follow the
[Neovim setup instructions](tools/tree-sitter-nua/README.md).
`make test-tree-sitter` checks the parser and highlighting in headless Neovim.
No changes to the compiler or your existing Lua filetype are required.

## Compiler and library

```sh
luajit nua.lua program.nua                      # print C
luajit nua.lua -o build/out.c program.nua        # write C (-H build/out.h for declarations)
luajit nua.lua -d program.nua                   # print staged Lua
luajit nua.lua -o build/out.c --cc program.nua   # also check strict C
luajit nua.lua --gccjit -o build/out.o program.nua
luajit nua.lua run program.nua args             # execute now, with an optional main export
```

From Lua, `require 'nua'` and call `nua.load(path)` to obtain exports, raw pointers
and FFI record types. A program can call `native(word)` to specialize on values
available at startup. See [the architecture](docs/architecture.md#14-the-toolchain) for error recovery,
code lifetime and foreign-library requirements. Direct invocations must have their dependencies on
the loader paths; Make's environment is not a system-wide installation.

A program's C is one file: it carries the runtime words it reaches (the runtime is
Nua, built with the program; `NUA_IO` selects the I/O backend). Beside it link
`runtime/nua_rt.c` when it includes `nua_rt.h`, `runtime/nua_io_uring.c` for io_uring,
and `-pthread` for tasks.
See [architecture §17](docs/architecture.md#17-status-limits-and-remaining-work) for
io_uring/kqueue support and validation limits.

## Fixed-size values at compile time

Known arrays and `Chars(n)` can remain immutable compiler data until they need
storage. Known-index updates and text reads can fold; dynamic operations and raw
address escape materialize conservatively. Value copies are snapshots, while
`:str()`/`:slice()` views retain their owner and observe later changes (with the
view's original length).

See the [staged-values example](examples/staged_values.nua) and
[the `Chars(n)` contract](docs/syntax.md#143-charsn). Its harnesses compare known,
split, C and in-process execution, including copies, live views and task captures.
This adds neither a compile-time heap nor a new borrowing policy.

## Activity case study: SDL3

[The interactive canvas](examples/canvas/README.md) wraps SDL3 in ordinary Nua
resource, input and frame activities. It includes a moving-rectangle example,
explicit failure/cleanup contracts, deterministic fault injection and real
headless SDL checks. With SDL3 installed, run `make test-canvas` and then
`./build/canvas/demo`.

## Source layout

| Part | Source |
|---|---|
| Driver / embedding entry | `nua.lua` |
| LuaMacro engine | `macro.lua`, `macro/`, `macro/lib/` |
| Nua application, lambdas, typed bodies | `macro/let.lua`, `macro/nua.lua` |
| Standalone source macro CLI | `luam` (`luajit luam -lmacro.let program.lua`) |
| Native types and exact folding | `nua/types.lua`, `nua/fold.lua` |
| Typed-body parser and translation | `nua/syntax.lua` |
| Specialization, state, words, control, tasks | `nua/stage.lua` |
| Goose storage and record layouts | `nua/memory.lua` |
| Immutable fixed-array contents | `nua/array_value.lua` |
| Text types and their compile-time fold | `nua/strings.lua` |
| Map and `StrMap` type hooks | `nua/maps.lua` |
| Module loader and compilation scope | `nua/loader.lua` |
| C / libgccjit backends | `nua/cgen.lua`, `nua/jitgen.lua` |
| Shared C rules / compiler-owned C reader | `nua/cjit.lua`, `nua/gccjit_h.lua` |
| Header probes / in-process execution | `nua/probe.lua`, `nua/native.lua` |
| Runtime policy build / `nua size` | `nua/runtime_build.lua`, `nua/size.lua` |
| Formatter | `nua/fmt.lua`, `nua/fmt_cli.lua` |
| Fuzzers | `tests/fuzz/gen.lua`, `tests/fuzz/fuzz.lua`, `storage.lua`, `tasks.lua` |
| Bundled libraries / runtime | `lib/`, `runtime/` |
| Examples, fixtures and checks | `examples/`, `tests/` |

[Architecture §18](docs/architecture.md#18-source-layout) has the complete table,
including the single-binary tools.

The macro layer is project source, **not a runtime bundle**. See
[its integration notes](docs/luamacro/INTEGRATION.md) and
[third-party attribution](THIRD_PARTY.md).

## Licence

Nua is free software under the GNU General Public License, version 3 or later
([COPYING](COPYING)). The runtime library (`runtime/`) and compiler-generated
runtime/header helpers additionally carry the GCC Runtime Library Exception,
version 3.1 ([COPYING.RUNTIME](COPYING.RUNTIME)), as specified by the incoming
prototype and alpha design. Third-party notices retain their own terms.

## Differential fuzzing

With LuaJIT/LPeg and libgccjit configured as above:

```sh
luajit tests/fuzz/fuzz.lua --regressions
luajit tests/fuzz/fuzz.lua --seed 424242 --count 10 --no-shrink --keep
```

The fuzzer compares known/native/split runs with C at `-O0` and `-O2`; every tenth
program also needs the C compiler's UBSan runtime. A failed compiler/link command
is not evidence of a value mismatch: inspect its diagnostic and keep the seed and
scratch output. The alpha roadmap specifies the broader planned campaign; these
commands do not establish that its nightly qualification gate has been met.
