# Handoff: continuing the memory-model milestones

Written 2026-11-03 for a new session (updated after milestone 4 closed). It says where the work stands, what the rules of the
road are, what is left and how to run things. Read it first, then `docs/design/memory.md`.

## 1. Read in this order

1. `AGENTS.md` (project rules) and the memory files in
   `~/.claude/projects/-home-cperion-ext-dev-nua/memory/` (loaded automatically).
2. `docs/design/memory.md`: the memory model, milestones (§13) and decisions D1–D12 (§15).
3. `docs/syntax.md`: the language contract. New in this stretch: §2.4 rules 11–12 (colon,
   `=:`, `with`, contextual `with`), §10.9 (`endall`), §15 (maps), §9.x (owners).
4. `docs/architecture.md` §7 (runtime model: stacks, owner slots, result region).

## 2. Repository state

- jj, colocated with git. `master` is still at `xyuqtlvy` (not moved). **Nothing is pushed**
  and no remote may be created without explicit authorization.
- The stack on top of `master` (oldest first; the change ids are stable):

| Change | What |
|---|---|
| `ukkkmnyr`, `tsutlrxq`, `vlnonmms`, `nkxwkltn`, `tukyywmu` | design draft; milestone 1 (stacks never move); milestone 2 (one borrow system) |
| `xnyzppkz`, `ozxxkzkl` | the memory design as a whole; docs for borrows in arrays/stores |
| `rrxssoyk`, `muxvmszz`, `zlwpounz` | milestone 3: the owner API, `U64` lengths, mutual recursion with owners |
| `vvsrzlqm`, `lzzmzykk`, `lpnluows` | sugar: trailing colon `f x:`, `=:`, `with` blocks |
| `opnnzorz` | `Struct` and `Sum` replace `struct` and `oneof` |
| `uymsyopt`, `uqwzkkul` | formatter writes multi-line tables as `with`; the code reformatted |
| `ttroklsl`, `qxtopmmo`, `qnmyskyt` | milestone 4: Map slot layout and real borrows, `Map(Str, V)`, `Map.borrowing`, `m[k] = v`, Grow `pop`/`truncate`, remove rules, compile-time `each` check |
| `nllxspxz`, `tpqzwnqk`, `vmwopkwk` | D12 design; library words state their borrow effects; one adapter for container methods |
| `rrlqvrsr` | `with` takes its type from its context (`return with`, typed locals, arguments) |
| `mmslrlpv` | step D1: Store/Grow/Array T are declarations the generic code reads |
| `tyokvvxu` | `endall` closes every open Nua block; the formatter folds end pyramids flat |
| `nwxwlqou` | the previous handoff |
| `vxsuwlnz` | step D2: `owner_type` declares `Store`, `Grow`, `Array`, the three Map families and the `Text` words in Nua; `nua/maps.lua` is gone; `TODO` builtin |
| `tqkvxqvk` | docs: code blocks of syntax.md and architecture.md in the current syntax (nua fmt) |
| `smowttts` | `Chars` is a library type (`lib/chars.nua`); `types.chars` is gone |
| `stlrwmkl` | `nua fmt`: `inline_with` (default 2) writes short tables on one line |
| `xzxzwrlw` | the repository's Nua sources reformatted with it |
| this change | this handoff |

- `klplprxp` (empty-described change under `master`) is the user's own work: leave it alone.
- **Last full-suite run** (end of milestone 4, on `xzxzwrlw`): `make test` **474 passed, 0 failed**, 2 skips
  (canvas and UI SDL: SDL3 not installed). Focused: native 976, rejection cases 155, colon 112,
  formatter 29/109/401, tree-sitter 84, map types, listings and guide. Milestone 4 is closed;
  `master` has **not** been moved (the user's decision is pending: to this handoff change).

## 3. Rules the user has set (do not re-ask these)

- **Full suite once, at the end of a milestone.** Use focused checks while developing; never
  start `make test` after a sub-step (`full-suite-at-end-only` memory).
- **Never narrow an approved design silently.** Ask first: do now / defer / drop. Never edit
  `docs/design/memory.md` to match a deviation. (`no-silent-scope-reduction`)
- **Audit every holder × role cell** and challenge inherited Goose/implementation limits before
  presenting a design (`design-audit-every-cell`). "Defaults should fit the language
  philosophy and make common use easy."
- **No pushes or remotes** without authorization. Describe changes before editing; own change
  per feature; end commit messages with the attribution line the harness gives.
- **Style:** same-line, paren-free calls (`Ref h`, `hash.init k0 k1`); trailing `do` blocks are
  curried out and written with the colon (`f x:`); mass style changes go through
  `nua fmt --write`, never an ad-hoc script (`nua-style-trailing-do`).
- Do not ask decided questions again. Do not delegate to other agents unless asked.
- Discuss material semantic or architectural changes and get approval before implementing.

## 4. What exists now (so you do not rebuild it)

**Memory model (design memory.md):** owners (`Grow`, `Array T`, `Store`, `Map`, `Text`), one
lifetime rule for borrows, tokens with liveness-based invalidation, moves at last use, results
placed in the caller's destination, `copy`, `Slice.mut`, payload borrows, `U64` lengths,
recursion with live owners (result stacks and a shared result region). Maps are slots that
never move plus a hash index; `m[k]` is a real borrow; `m[k] = v` inserts; `Map(Str, V)`
replaces `StrMap`; `Map.borrowing(Str, V)` keeps the caller's keys.

**Borrow effects of a library owner type (D12, memory.md §10.1):** the library states them with
`__S.retire(owner, template, key?)`, `__S.restructure(owner, what, key?)`,
`__S.borrows(owner, value)` and `__S.grows(owner)`, and `fixed` is the compile-time `each`
lock. Effects are summarized across words (`fn.shrinks`, `fn.restructures`, `grow_sites`).
`lib/storage.nua`, `lib/map.nua` call them. `__S.fixed(owner, body)` is the lock itself.

**Library owner types are declarations (design §10.1, step D2):** `lib/owners.nua` calls
`__S.owner_type{ name, header, stacks, api, init, methods, args, arity, index, extra, … }` for
`Store`, `Grow`, `Array`, and (through `map.family` in `lib/map.nua`) `Map`, `Map(Str, V)`,
`Map.borrowing`. `nua/memory.lua` is the one generic reader (`decorate`, `adapter` with argument
kinds `index`/`key`/`stored_key`/`value`, `index_hook`, `length`); `types.owner` is the one type
constructor. Declarations are made again by every compilation (`Mem.prelude` loads `nua.owners`
inside the compilation). `Text` is `Grow U8`: its `write`/`str` are words in `lib/storage.nua`
(`write` takes `..parts`, unrolls and joins known text); `Chars n` is `lib/chars.nua` (a struct
with `chars_cap`, a `length` property word, a host `str` member and constructor). `Str` stays a
compiler type by decision. `TODO "msg"` is a prelude builtin (an alias of `trap`).

**Syntax added:** trailing colon (`f x:`, `xs:each: k v`, `tasks: scope..`), `key =: x`,
`T with … end` (commas optional; entries by `name =`, `name:`, `.name`, a line of their own),
contextual `with` (the expected type supplies the constructor), `Struct`/`Sum`, `endall` over
every Nua block. All of these are **token rewrites** in `nua/colon.lua` (see §5). The formatter
(`nua/fmt.lua`) round-trips them: it expands to braces, formats, then `withize`, `foldends`,
`colonize`. Options: `block_style`, `data_style`, `spine_style`, `inline_with` (default 2: a head table of
one or two plain entries that fits the column goes on one line in braces; `nua/colon.lua`
`inline_tables`).

**Diagnostics worth knowing:** `f -1` on a word explains the subtraction; unclear
`push i * 10` still says `unexpected '*'` (not yet improved).

## 5. File map for the machinery you will touch

| Concern | Where |
|---|---|
| owner slots, moves, releases, the generic reader of owner-type declarations | `nua/memory.lua` |
| owner-type declarations; Map families, key capture, `each`, known maps | `lib/owners.nua`, `lib/map.nua` |
| `Text` words; `Chars`; `Str` (compiler type) | `lib/storage.nua`, `lib/chars.nua`, `nua/strings.lua` |
| container and map algorithms (Nua) | `lib/storage.nua`, `lib/map.nua`, `lib/storage_layout.nua`, `lib/stacks.nua` |
| borrow tokens, effects, checked places | `nua/stage.lua` (`h.place_tokens`, `S.retire`, `S.borrows`, `S.note_structure`, `h.check_use`) |
| token rewrites (colon, `=:`, `with`, `endall`) and the formatter passes | `nua/colon.lua` |
| formatter | `nua/fmt.lua`, `nua/fmt_cli.lua`, `nua/application.lua` |
| typed-body parser (`endall` for lambdas) | `nua/syntax.lua` |
| C runtime header and harnesses | `runtime/nua_rt.h`, `tests/map_reference.h`, `tests/*_main.c` |
| tree-sitter | `tools/tree-sitter-nua/` (CLI in `.local/tree-sitter`, git-ignored) |

## 6. Commands

The Makefile sets the environment; run through it:

```sh
make test-macros      # macro engine + tests/colon.lua
make test-format
make test-tree-sitter TREE_SITTER=$PWD/.local/tree-sitter/node_modules/.bin/tree-sitter
make test-native      # in-process libgccjit checks (tests/native.lua)
make test             # the complete suite (long)
```

Focused loop while developing (LuaJIT with the repo environment; recreate these small
helpers, they were scratch files): load a `.nua` with `require('nua').load(path)` and call an
export; run the rejection table `dofile('tests/errors.lua')` through `nua.compile(case.src)`
and compare `case.expect` with the error text; format with `require('nua.fmt').format`.
`.local/bin/luajit` needs `LUA_CPATH`/`LUA_PATH` from the Makefile (`.local/lib/lua/5.1`).
Skips are expected for canvas and UI SDL (SDL3 not installed).

jj: `jj new -m "…"` starts a change; `jj squash --from @ --into @- <paths>` moves files down;
pass `-u </dev/null` or avoid commands that open an editor.

## 7. Traps found the hard way

- `nua/stage.lua` is at Lua's **200 local variables** limit for its main chunk. Add helpers as
  fields of `h` (the staging table) or `S`, never new `local`s at file level.
- A function parameter named `ref` shadows `stage.lua`'s `ref(place)` constructor.
- `Builder:read` of a struct place rebuilds an aggregate and used to drop the stored borrow
  tokens; reads now carry `h.place_view`. Check this path first if stored borrows misbehave.
- A word with a typed result (`do(n: U32): T`) is a **word body**: `endall` and the `with`
  rewrite treat it as a boundary. Expression lambdas (`do(x) = e`) have no `end`.
- Do not `rawset` view attributes on shared values; copy first (`with_view`).
- Editing the tree while a background `make test` runs corrupts the run (docs too: the suite
  compiles their examples).
- `__S` is reserved inside typed `do` bodies: call host helpers defined outside the word.
- The prelude loads Nua modules, so `nua.prelude()` only works inside a compilation.
- A struct method word receives `self` as a `Ref`, and a spawned task refuses to capture a
  reference to an outer local: that is why `Chars:str` is a member hook, not a method word.
- `tests/colon.lua` pins `inline_with = 0` for its `with` cases; `tests/formatter.lua` has the
  `inline_with` cases. `make test-format` takes about 5 minutes.
- A stage of `make test` that fails stops `make`: later stages are unverified until it passes.

## 8. What is left (in order)

**Milestone 4 is closed.** Deliberate remainder: `Chars:str` and the `Chars` constructor are host
hooks (see §7); the checked-place index hook is the generic protocol in `nua/memory.lua`;
`Str` is a compiler type.

**Later milestones (memory.md §13):** 5 nested owners (arenas, `compact()`, owner globals;
reuse the `Map(Str, V)` key-arena code); 6 capacity sizing per tasks scope; 7 task borrows with
frozen owners (D1). Deferred by decision: D4 atomics in containers, D8 general last-use release.

**Small leftovers:** `docs/designing-and-writing-nua.md` still has the older spellings: its
blocks are verbatim excerpts of `examples/guide.nua` (tests/guide.lua), so change both together;
`docs/formatting.md` has a duplicated `block_style` row; clearer diagnostic for `push i * 10`;
the obsolete `nua/experiments/binary/reject_mutate_borrow.nua` and the old `struct`/`oneof`
spellings under `nua/experiments/` (raw evidence, intentionally untouched); stale
`/tmp/nua_io_test.bin`; tree-sitter limits (entries of a `with` on one line need `,` or `;`; a
`.name` entry on a new line after a value reads as member access); `spine_style` `"pure"` and
`"all"` behave the same for `with` chains; `Store` ends every element borrow on `remove`
while `Map` refines by known keys; `Map.known` and owner values in maps wait for milestone 5;
the fixtures `tests/with_blocks.nua`, `tests/formatter/input.nua` and the tree-sitter sample are
intentionally not reformatted.

## 9. Decisions awaiting the user

- Move `master` to the handoff change (stack above; nothing is pushed).
- The `endall` fold threshold is three blocks including a `with`.
- Whether the formatter should reorder `failed = …` entries so the deep handler comes last
  (it does not; folding needs the source order).

## 10. How to start the next session

1. `jj status`, `jj log -r 'ancestors(@, 30)'`, read §2 above against it.
2. Run the whole suite once (§6) and record the numbers (expect 474 passed, 2 SDL skips).
3. Ask the user which of §8/§9 to take, then follow the rules in §3.
