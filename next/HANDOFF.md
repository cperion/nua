# Nua rewrite in Mua: handoff for optimizer, JIT backend and scheduler

## Where the rewrite stands

The Mua compiler in `next/` compiles everything in `docs/syntax.md` except tasks, channels,
pools and I/O (§20). It emits C only. `make test-next` last reported **216 passed, 0 failed**,
on the working copy described below.

**Language and library, working and tested end to end:** sums and matching, parts and partial
moves, `Ref` handlers, members and hooks, `Slice`, `Str`, UTF-8, static text folding, branch
proofs, lending, arrays and owner `Array T`, `copy`, `Text`, Schubfach float text in Nua,
`Chars(n)`, `Store`/`Id`, `Map`, `Map.known`, pinned buffers, `finish`, globals, rest
requirements and packs, opening (records, tables, store slots, anonymous homes), keyed spread,
`fnptr`/`Fn`, `Atomic T`/`fence`/`atomic_ptr`, foreign calls with
`cconst`/`cread`/`cstruct`/`cformat`, compile-time `test`/`assert`, and `lib/libc.nua` and
`lib/posix.nua`.

**Not started, and the subject of this handoff:** the optimizer and preparation passes, the
libgccjit backend, and the scheduler with the rest of §20. The old compiler in `nua/` still
runs and stays until cutover.

**Version control.** All work is in the jj stack below `@` on top of `master`; nothing is
pushed. The top change is `pqumypyu`, and the working copy holds it, described. `master` has
not moved.

**Mua pin.** `tools/mua.lock` pins commit `50a7a86`, which exists only on branch
`struct-member-fallback` of `~/dev/mua-member`. The push was blocked in the last session, so a
fresh `make mua` from GitHub cannot find that commit until you run
`git -C ~/dev/mua-member push origin struct-member-fallback`. Until then, install with
`MUA_URL_OVERRIDE=$HOME/dev/mua-member make mua`.

## How to work in this repository

These are the rules the last session was corrected on. `AGENTS.md` is the authority; this is
what they mean in practice.

- **Nua first.** Every algorithm that can be expressed is an ordinary Nua word in `next/lib/`,
  so it specializes with the program. The compiler supplies only the smallest general
  primitive. The scheduler is the place this will be tested hardest: its algorithms belong in
  Nua over mechanisms, not in C or Mua.
- **Authorities.** `docs/syntax.md` owns language contracts,
  `docs/design/compiler-activities.md` the compiler, `docs/design/buffers.md` storage,
  `docs/design/tasks.md` tasks. Do not edit a design doc to match a narrower implementation;
  ask first.
- **Residualization is the principle.** Host application evaluates in place; it does not skip
  the body.
- **Mua style.** Large tables are `define … end`. Metatabled objects use `meta with … end`.
  Members are `function T:name(...)`. No abbreviated names. Parenthesis-free calls in Nua,
  trailing `do` curried out.
- **Mua traps that cost time.**
  - `name -> do(a, b) … end` parses as a block-bodied short function.
  - Never write `c and nil or x`.
  - A top-level untyped `do(...)` is a plain Lua function, not a word; give it a `: Inferred`
    result to make it one.
  - In a `define`, `.name` straight after an entry that ends in a call continues that call, so
    put shorthand entries first.
  - A line ending in a call followed by a bare `do` on the next line is a trailing block.
- **Running.** Use `.local/bin/luajit`, because `/usr/bin/luajit` lacks 3.0 syntax. Focused
  checks are `.local/bin/luajit next/test.lua <name>`. `make test-next` runs once per
  milestone, about two and a half minutes.
- **Tests.** `tests/support/native.mua` refuses two tests that export one name with different
  prototypes, so export names must be unique across the suite.
- **History.** jj only, described before editing. No remotes or pushes without being told. Do
  not touch the uncommitted work in `~/dev/mua`.

## Map of next/

One evaluator builds one Program graph; the three packages attach around it. A word reaches
the graph only through evaluation, and library code enters the same way as program code.

```text
 [Package 3: scheduler in Nua]        not built
              |
              v
       next/lib/*.nua                 library algorithms as Nua words
              |
              v
 nua/front.mua ----------> nua/compiler/evaluation/
 Mua host, lexical scopes,   the one vocabulary E: known and residual evaluation,
 opening, argument capture   borrows, moves, joins, loops, members and hooks
                                      |
                                      v
                    program.mua, graph.mua, definitions.mua
                    one Program graph with boundary contracts,
                    one definition per requested specialization
                                      |
                                      v
                    verify.mua, verify_lifetimes.mua, boundaries.mua
                    independent checks of shape, types and lifetimes,
                    replay of native boundary contracts
                                      |
                                      v
                    [Package 1: optimize, budgets, prepare]   not built
                    folding, budget coverage, recomputed facts,
                    ReadyCertificate
                          |                       |
                          v                       v
                     emit_c.mua        [Package 2: libgccjit]  not built
                     C, built          same prepared IR
```

| Path | Holds |
|---|---|
| `nua/compile.mua` | The prelude and environment (`extern`, `global`, `cconst`, `test`, `require`), the primitive list, and `compile`/`compile_c` |
| `nua/types.mua` | Native types, layouts, kinds, the member and family registry |
| `nua/compiler/hosting.mua`, `bridge.mua` | Words, applications, primitives, foreign objects; Lua called from evaluation |
| `nua/compiler/facts.mua`, `proofs.mua`, `contracts.mua` | `FlowFacts`, borrow tracking, what branches prove |
| `nua/compiler/rules.mua` | Opcodes: their type rules and folds |
| `nua/compiler/platform.mua`, `runtime/nua_platform.h` | Platform mechanisms, the only C the design keeps |
| `tests/`, `tests/support/native.mua` | The suite, and the harness that compiles C and loads it through FFI |

## What this rewrite added to the design

These are not in the old compiler. New work should build on them rather than around them.

| Addition | Where | Meaning for the next session |
|---|---|---|
| Argument capture | compiler activities §5.1, `E.capture_argument` | Arguments are read, moved or lent under their requirement at the call. |
| `BorrowInfo.source` | `places.mua`, lifetime replay | A derived borrow names the borrow it came from; passes that copy borrows must keep it. |
| Branch proofs | `proofs.mua`, `FlowFacts` `proved`, `bounds`, `available` | Proved checks are never emitted. The optimizer starts with these already gone. |
| `vacated`, `fixed` facts | `facts.mua` | Partial moves, and map structure held during `each`. |
| One atomic primitive | `atomic_operation`, `lib/atomic.nua` | The operations are Nua words; `E.atomic` appends `data.Atomic`. |
| `ForeignValue` constants | `values.mua` | A header's constant is a constant operand that is never folded and is not known. The JIT must get its value by probing. |
| `Foreign.reads` | `program.mua` | A zero-argument `Invoke` spelled as a variable read (`errno`). |
| `RecordType.c_name`, `Field.c_member` | `types.mua` | The layout belongs to the header; `emit_c` spells members from these. |
| `Program.headers` | `program.mua` | Headers a program needs beyond its foreign calls. |
| `DefinitionAddress` reachability | `graph.called_definitions` | An address taken counts as a use, wherever the constant travels. |
| Compilation-scoped hooks | `types.registry` | Members and families are per compilation. |

## Work package 1: optimizer and preparation

**Contract:** compiler activities §7.3 and §7.4. The driver order is fixed: close and verify,
then optional folding and reachability, then budget coverage with facts recomputed, then
readiness and a `ReadyCertificate`.

**Build, in this order:**

1. `nua/compiler/optimize.mua` with `fold`, `reach`, `sweep`, `optimize`: at most eight rounds,
   stopping on graph-aware equality, each round leaving a valid program. Input is never
   mutated; `graph.rewrite` already owns its output.
2. Recomputation of graph, alias, effect and lifetime facts for changed definitions.
   **`effects.mua` currently answers empty for `Atomic` and `Fence`**, and that must change
   before any pass reorders memory operations.
3. `prepare program analysis -> Prepared` with `ReadyCertificate { revision, definitions }`,
   the `ready` verifier, and backends refusing a bare `Program`. `emit_c` does not check a
   certificate today.
4. `LifetimeStart` and `LifetimeEnd` are in the IR but the evaluator does not emit them. Decide
   what the optimizer needs from them, then emit them at lexical scopes.

**Opportunities already visible in the output:**

- Store slot lookups: syntax §10.6 says uses that nothing separates share one check. Today
  every use checks. `FlowFacts.borrows` has a `cached` state with handlers in `references.mua`
  and `views.mua`, but nothing sets `state.pointer`, so that path is dead code awaiting this
  work.
- Dead pure results from inlined words.
- Known-round compile cost: a recursive word called with a known count re-evaluates
  quadratically in depth. Depth 16 took 106 seconds. The boundary rebuild loop in
  `definitions.mua` `close` is the place to look, and this needs fixing regardless of the
  optimizer.

## Work package 2: libgccjit backend

**Contract:** C and libgccjit consume the same prepared IR, with no duplicated semantics or
runtime definitions (`AGENTS.md`, compiler activities §1).
`emit prepared target -> BackendProduct`. It depends on the certificate from work package 1.

**What exists to reuse:** the old `nua/jitgen.lua` (993 lines), `nua/cjit.lua` (1890 lines, C
type rules and a reader for the runtime header's C subset) and `nua/probe.lua` (257 lines,
compiles and runs a small C file to learn header values). The approach carries over, but
**jitgen was built around task frames and step functions, which the new design removes**. Do
not port that part.

**Every IR kind `emit_c.mua` spells needs a counterpart:**

- `ForeignValue`, `cread` and `cstruct`: libgccjit reads no headers, so these go through the
  probe (architecture §11). `size_of` of a `cstruct` is a `ForeignValue` too. A `cstruct` needs
  its probed size, alignment and member offsets.
- `Atomic` and `Fence`: `__atomic` builtins through gccjit's builtin lookup. `compare_exchange`
  needs a local for the expected value.
- `Invoke` over `DirectNua`, `IndirectNua`, `Foreign` (including `reads` and variadic casts).
- Components, `ElementComponent` on arrays, sums as tag plus union, `ZeroBits`,
  `StaticAddress`, `SymbolAddress`, `DefinitionAddress`, and `Global` policies including
  `__thread`.
- Mechanisms in `nua/compiler/platform.mua`, including the new `reserve_range`, `commit_range`,
  `release_range`, `next_store_token` and `hash_seed`.

**Acceptance:** the old project's bar was byte-identical C with and without the gccjit backend
present, and every example passing through both. Run the native test suite through both
backends. `tests/support/native.mua` builds with C only today and needs a backend parameter.

## Work package 3: scheduler, tasks and §20

**Contract:** `docs/design/tasks.md`, compiler activities §7.2, syntax §20, buffers §2.6. A task
runs on its own nonmoving native stack. There is no typed frame, step function, wait state or
wait mode, and no OS-thread fallback.

**What is new compared with the old compiler:** spawn, wait and budget service are ordinary Nua
words of a scheduler library, over platform mechanisms. Old `runtime/scheduler.nua`,
`tasks.nua`, `protocol.nua`, `poll.nua` and `uring.nua`, and `lib/channel.nua`, `select.nua`,
`io.nua`, `stacks.nua`, are reference material for the algorithms, and will need rewriting
against this model.

**Build:**

1. Context and stack mechanisms in `platform.mua` and `runtime/nua_platform.h`: stack
   reservation with a guard page, and the context switch. C and assembly hold only these.
2. `nua/compiler/budgets.mua`: `Budget` points on loop and native-call cycles, in the
   preparation order of work package 1.
3. The scheduler library in Nua, then `Chan`, `Pool`, `Slot`, `spawn`, scopes, `first_of`, and
   I/O by completion.
4. `TaskEntry` as the entry ABI of a task's definition (`NativeABI` already has `task_entry`,
   and `DefinitionKind` has `task_entry_word`).
5. The `task_access` verifier: parameter, global and callback origins over the reachable call
   graph.

**Already in place to build on:** `Atomic T` and fences, `Global.policy` (`thread_local`,
`unchecked_shared`, `thread_affine_owner`), pinned buffers (a stack is a pinned reservation),
`fnptr`, and the `may_reenter` field of foreign contracts.

**Watch for:** `global` records `thread_affine_owner` for an owner global, but nothing enforces
the task prohibition yet, because tasks do not exist. A word whose effects include `may_wait`
must be refused as a C callback, and `fnptr` does not check that today.

**Acceptance:** the §20 tests, deterministic scheduling, sanitizer paths where available, and
through both backends once work package 2 lands.

## Known limits, loose ends and cutover

**Language limits in the current compiler:**

| Limit | Effect |
|---|---|
| `require` | `require "nua.x"` maps to `import`; other names go to Lua's `require`. The per-compilation `package.loaded` and program-directory search of syntax §2.1 are not built. |
| `F32` text | Printed through `F64`, so the shortest form is not `F32`'s own. |
| `parse(F64)` | Uses libc `strtod` at run time; known text folds. |
| Arrays holding borrows | Not tracked after the array is materialized. |
| Foreign call given a scoped view | Not refused, though the view could be retained. |
| Store tokens | The counter is per C unit, so two units can issue the same token. |
| Rest requirements | A word with one cannot cross a `call` boundary or be taken by `fnptr`. |
| `Map.known` | Passing one across a `call` is not refused, though §15.3 gives it no native ABI. |
| `Grow` of a `cstruct` | Refused with a raw Lua error (`bad argument #1 to 'max'`): buffer element sizes are host numbers, and a `cstruct` has no compile-time size. |
| Packed `cstruct` fields | Reads through a pointer load the field alone. `Ref` of a packed field still takes its address, and GCC warns. |
| Libraries not ported | `canvas`, `sdl`, `ui`, and everything depending on §20. |

**Diagnostics:** source-line errors only. The structured related-location diagnostics of
`diagnostics.mua` are not built.

**Cutover needs:** the three work packages, the documented acceptance obligations, the examples
and harnesses of `tests/run.lua` passing on the new compiler, and `make doctor`, `make test` and
`make test-native` pointed at it. Passing the current suite does not establish this. Then `nua/`
is deleted, and any `docs/` passages that describe it (architecture §11 in particular) need
rewriting.
