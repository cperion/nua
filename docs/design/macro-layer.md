# Separating the macro layer (design)

Status, 2026-11-04: **steps 1–5 implemented; Mua lives in its own repository** (`mua/`, its tests, its surface syntax doc and its guide moved there; Nua pins it with `tools/mua.lock`, `make mua`). LuaMacro and LPeg are removed. Not done: the formatter's remaining text passes (`colonize`, `withize`, `foldends`, `inline_tables`, `mark_tables`, still token heuristics in `nua/colon.lua`), moving the generic formatter into the Mua repository, and the tree-sitter corpus check (the `tree-sitter` CLI is not installed here). `colon.rewrite` is gone: `colon.expand` is driven by Mua's parser.

Goal: the macro layer is **Mua, a Lua language, and nothing else**: sugared Lua in, plain Lua out,
for any Lua program, with structural `define` types as its way of naming things. It is our
own pure-Lua lexer, parser and emitter, loaded with `loadstring` (or from cached bytecode);
LuaMacro and LPeg are no longer used (decided 2026-11-04). Nua is one client (a *host*) of
it. Once Mua stands on its own, the compiler can be written in it; that migration is
the next design, made on top of this one (§11).

## 1. Today

Source becomes Lua in five steps (`nua.translate`, `nua.lua:148`):

| Step | File | Does |
|---|---|---|
| 1 | `nua/colon.lua` `rewrite`, a lexer hook installed by `macro/nua.lua` | token rewrites: trailing colon, `=:`, `T with … end`, contextual `with`, `endall` |
| 2 | `macro/nua.lua`, a lexer hook | `.name` entries; keyed spread `{ ..base }` → `__nua_keyed{ [__nua_spread(1)] = base }` |
| 3 | `macro/let.lua` | lambdas, opened `do(..)` (a `setfenv` environment), juxtaposition (token marks `__let_apply`), `ULL` literals, Lua's `do` vs a lambda |
| 4 | `macro/nua.lua` → `nua/syntax.lua` | typed lambdas (`M.let_typed`), opened lambdas (`M.let_opened`), typed `function`, `struct`, `oneof`, `export`: parsed by syntax.lua's parser `P`, translated by its generator `G` into `__S.*` calls, spliced back as text padded to the source's line count |
| 5 | `nua/syntax.lua` `statement_calls` | re-parses the expanded Lua with `P`, adds `()` to bare-name statements |

The formatter (`nua/fmt.lua`) runs step 1 (`colon.expand`), parses whole files with `P`, prints,
then runs colon.lua's text passes (`withize`, `foldends`, `colonize`, `inline_tables`). So `P`
already parses every file of the repository.

**Nua inside the layer that should be Lua only**

- `macro/let.lua` knows Nua's hooks (`let_typed`, `let_opened`, `__typed_function`) and its
  diagnostics ("native words are written do(x: T): R").
- `nua/colon.lua` detects typed lambdas; its contextual `with` emits a call to `with`, which
  only Nua's prelude defines (`S.contextual`).
- Keyed spread emits `__nua_keyed`/`__nua_spread`, which only Nua's prelude defines
  (`S.keyed_table`, `S.spread_mark`); their plain-table half lives in the compiler
  (`S.keyed`, `nua/stage.lua:6049`).
- An opened `do(..)` has two implementations: macro.let's `setfenv` environment, and `G`'s
  lexical resolution through `__S.oname`/`ocall`/`oset` when Nua is loaded.
- `nua/syntax.lua` holds a Mua parser (`P`) and Nua's generator (`G`) in one module.
- `nua/application.lua` mixes generic call-chain analysis with facts about Nua words, externs
  and prelude arities.

**One rule, written several times**

- Juxtaposition: token marking in macro.let, `P:suffixed_from`, the tree-sitter grammar, the
  formatter.
- Which `do` is a lambda: colon.lua's block stack, macro.let's `do` macro and loop count, `P`.
- Typed-form detection: colon.lua, macro.let, macro/nua.lua.

**Unused:** LuaMacro's library macros `lc`, `forall`, `try`, `assert`, `module`, `ifelse`,
`lambda`, `with`, `do`, reached only through `macro/all.lua`, which only `tests/macros.lua`
loads.

## 2. Principles

1. **Two layers, the dependency one way.**
   ```
   nua/       the host: typed forms' meaning, records, contextual typing, the compiler
   mua/   Mua: lexer, parser, AST, emitter, loader, analysis, runtime,
              formatter core
   ```
   Nothing in `mua/` names `__S`, `nua.*`, a native type or C.
2. **Mua is plain Lua with no dependencies:** no LPeg, no native module, LuaJIT's
   standard library only. It is the bootstrap level: the compiler may be written in the
   Mua later, but Mua itself is not.
3. **Useful on its own; one door for a host.** Every form has a pure-Lua meaning, typed forms
   included (§4.7, §4.8). A host changes meaning only through the host interface (§5): it
   replaces the meaning of the forms it translates and overrides the runtime's documented
   entries (§4.5).
4. **Each surface rule exists once:** in Mua's parser. The tree-sitter grammar is a
   second technology and is checked against Mua's cases, not trusted (§8).
5. **No program changes meaning** except the behaviour changes §9 lists.

## 3. Mua's forms

| Form | Plain-Lua meaning |
|---|---|
| `do(x) = e`, `do(x) … end`, `do … end`, currying | functions |
| juxtaposition `f a b`, `f 21`, `f "x":rep 3`, `f (g x) y`, a newline ending a name chain | curried calls `f(a)(b)`, as macro.let gives today |
| bare-name statement `f` | `f()` (today's `statement_calls`) |
| trailing colon `f x:`, `xs:each: k v` | a trailing block lambda |
| `key =: x` | as syntax.md describes it today |
| `T with … end` | `T{ … }` |
| `with … end` where an expression starts | `__mua.with{ … }`: the identity by default (§4.5) |
| `.name` entry | `name = name` |
| keyed spread `{ ..a, k = v, ..b }` | `__mua.keyed{ … }` (§4.5) |
| `endall` | closes every open Mua block |
| `do(..)`, `do(ctx..)`, `local ctx.. = e` | opening (§4.4) |
| `42ULL`, `7LL` | LuaJIT's literals |
| typed lambda or `function` (a result annotation), typed parameters and locals inside it | a function with **contracts** (§4.7); a host replaces the meaning (§5) |
| `struct { field: T, … }`, `function T:m(…)` | a nominal record type with checked fields and methods (§4.8); a host replaces it |
| `oneof { alt: T, … }`, `s { alt = do(p) … end, … }` | a tagged union with constructors and exhaustive matching (§4.8); a host replaces it |
| `export name` (a statement keyword a host registers) | no meaning without a host: an error naming the missing host |
| annotations on an untyped lambda's parameters | dropped, as today |

`define` is not syntax: it is a runtime word (§4.5).

## 4. Mua

### 4.1 Lexer

`mua/lex.lua`, written fresh in plain Lua (not derived from LuaMacro's lexer): Lua 5.1 tokens with LuaJIT's literals (hex,
hex floats, exponents, `ULL`/`LL`/`i` suffixes), long strings and comments with `=` levels,
escapes, the `.`/`..`/`...` split. Each token carries its kind, text, line and column;
comments and spacing are kept as tokens, so the formatter round-trips a file byte for byte.

### 4.2 Parser and AST

`mua/parse.lua`: a recursive-descent parser over those tokens, built from
syntax.lua's `Reader` and `P`, extended to what steps 1–3 do today (the trailing colon,
`with`, `endall`, `=:`, `.name`, spread, the Lua-`do` rules). Its AST is `P`'s, documented in
the module (node kinds `name`, `call`, `method`, `lambda`, `table`, `local`, `assign`, … with
source lines). Tools get the token list with the AST (comments, spelling, positions).

### 4.3 Emitter and loader

`mua/emit.lua` writes an AST as Lua text, each statement on its source line (no padding
pass, no re-scan), so Lua's own error positions are the source's. A typed form's node is
handed to the host, which returns its Lua text; the emitter places it at the node's line.

`mua/load.lua` compiles that text with `loadstring(text, '@' .. file)` and provides a
`package.loaders` searcher for Mua modules and a `dump` of the emitted Lua for
debugging. **Bytecode cache:** a module may be loaded from `string.dump` output kept under
`.cache/`, keyed by the source's hash, Mua's version, the host's version and the
LuaJIT build; any mismatch recompiles. Debug information is kept (not stripped), so
tracebacks keep file and line. The cache serves start-up time once the compiler itself is
written in Mua (§11); a program compiled by Nua still goes through its host.

### 4.4 Opening, one semantics

Inside an opened block, a name that is not bound lexically resolves to the innermost opened
context that **introduces** it, else to the enclosing environment; assignment resolves the
same way. Calls of an opened member are plain calls (a vocabulary entry takes no receiver).
The emitter resolves names lexically (it knows the chunk's bindings); only free names inside
opened blocks are resolved at run time, through locals and a ternary chain, with no
allocation (E1). What a context introduces and how a member is read, written or called is
the runtime's `open` (§4.5): for a Lua table, its string keys when it is opened. Nua's override
adds records (fields as places) and methods (with the receiver).

### 4.5 Runtime

`mua/runtime.lua`, plain Lua, reached by emitted code as `__mua` (in the chunk's
environment). A host passes a table of overrides when it translates; entries it does not
override keep the defaults.

| Entry | Default |
|---|---|
| `keyed(t)` | spreads (marked keys, source order) then explicit fields; a field from two spreads is an error; explicit fields override; result a new table |
| `spread_mark(n)` | the marker key of the n-th spread |
| `entries(source)` | the string keys of a table, sorted; anything else is an error |
| `finish(fields, names, sources)` | `fields` |
| `with(t)` | `t` |
| `define(t)` | `t` (also bound as the global `define` for Mua programs) |
| `open(ctx)` → `names, ctx` | §4.4 for Lua tables: the set of string keys it has when opened, and the table itself (E1) |
| `closed`, `required`, `optional` | §4.6 |
| `check(T, v)`, `Number`, `String`, `Boolean`, `Table`, `Function`, `Any`, `Unit`, `Optional(T)` | §4.7 |
| `struct`, `oneof` | §4.8 |

Nua overrides `entries` and `finish` (records: `h.record_fields`, the `Keyed` constructor
result), `with` (`S.contextual`), and `open` (names and a proxy over `S.open`'s receiver). The
compiler's `S.keyed` keeps only the record half.

### 4.6 Structural types

A structural type is a `define` table: names bound to defaults, words or vocabularies. The
type is its own default; an instance is the type spread with overrides
(`{ ..Margins, right = 12 }`), and an instance can serve as a type. This is pure Lua and
needs nothing from a host.

Two gaps matter once the compiler's own data (IR nodes, places, slots) is written this way:

- **A Lua table cannot hold a key whose value is nil,** so a field without a default cannot
  be declared. Two runtime markers: `required` (an instance must supply it) and `optional`
  (it may be absent; an instance without it has nil there).
- **A vocabulary is open:** a misspelled key silently adds an entry. `closed(t)` marks a
  structural type closed: a keyed spread whose sources include a closed table rejects an
  explicit field none of them declares, and rejects a missing `required` field; the result
  is closed too, so instances stay checked.

```lua
local Store = closed define with
    op = "store"
    place = required
    e = required
    what = optional
end
local st = { ..Store, place = p, e = value }      -- checked: no unknown key, both required present
```

Both are runtime words in `mua/runtime.lua`; no syntax changes. Their cost is a check at
construction.

### 4.7 Contracts

Without a host, an annotation is an ordinary expression that evaluates to a **checker**,
once, when the function (or type) is created. A typed function checks its arguments on entry
and its returned value at each `return`; a typed local is checked when it is initialized and
at each assignment. A result annotation describes one returned value.

A checker is anything `check(T, v)` accepts:

- a built-in: `Number`, `String`, `Boolean`, `Table`, `Function`, `Any`, `Unit` (no value),
  `Optional(T)` (nil or a `T`);
- a predicate function: `v` passes when `T(v)` is true;
- a closed structural type (§4.6): `v` has its `required` fields, no field it does not
  declare, and fields that pass the type's annotations;
- a `struct` or `oneof` (§4.8): `v` was built by it.

A failed check raises an error naming the parameter, local or result, the annotation and the
value, at the source line.

**The off switch:** a loader option (`contracts = false`, per loader or per module) makes the
emitter drop every check; annotations then cost nothing and are documentation only.

Checks run at run time: they are contracts, not proofs. A host gives annotations its own
meaning (Nua: native types, checked while compiling).

### 4.8 struct and oneof

Structural by default, nominal when declared (design guide §4): a `define` type is matched
by its shape (§4.6); a `struct` or `oneof` is a declared type, and its values are the ones it
built.

- **`struct { field: T, … }`** is a closed structural type whose fields carry annotations,
  plus a brand: its constructor (`Point { x = 1, y = 2 }`, `Point with … end`, spread with
  overrides) checks the names, the `required` fields and each field against its annotation,
  and gives the instance the struct as metatable. `function Point:norm(): Number … end`
  defines a method; instances reach it through the metatable. Defaults and spread rules are
  `define`'s.
- **`oneof { circle: Number, square: Number, none: Unit }`** gives constructors
  (`Shape.circle(r)`, `Shape.none()`), each payload checked against its annotation. A value
  is matched by calling it with a handler table: `s { circle = do(r) … end, square = …,
  none = do … end }`. **Every match checks** that the handlers name every alternative and no
  other (one walk over the sum's alternatives), then calls the selected handler with the
  payload.

Both are runtime words in `mua/runtime.lua`, spelled the same as in Nua, so code moves
between a Lua script and a Nua program without changing its spelling.

### 4.9 Analysis

`mua/scope.lua`: lexical bindings, opened regions and call-chain normal forms over the
AST, the generic part of today's `nua/application.lua` (`analyze`, `chain`,
`word_arguments`, `regroups`). It takes a **fact provider** for what a callee is (a declared
arity, a module's exports); Mua'supplies none beyond the AST itself.

## 5. The host interface

```lua
local mua = require 'Mua'
local lua = mua.translate(source, filename, host)   -- plain Lua text
local ast, tokens = mua.parse(source, filename, host)

host = {
    typed_lambda   = function(node, cx) return text end,   -- do(x: T): R ...  (whole subtree)
    typed_function = function(node, cx) return text end,   -- function a.b:m(x: T): R ...
    struct         = function(node, cx) return text end,   -- struct { field: T, ... }
    sum            = function(node, cx) return text end,   -- oneof { alt: T, ... }
    statements     = { export = fn },                       -- export name [as "c"]
    facts          = function(callee_node, env) ... end,    -- for analysis and the formatter
    runtime        = { ... },                               -- §4.5 overrides
}
```

A host replaces Mua's meaning of each form it translates (§4.7, §4.8 are the defaults
when there is no host); a file goes through one meaning or the other, never both. A
translator receives the node with its whole subtree (nested untyped lambdas included: in
Nua they are host bodies with staged operators) and a context `cx` giving the file name, the
node's lines, errors at a line, and Mua emitter for any subtree the host wants as
plain Lua. Translators return text; the emitter keeps lines.

## 6. Nua as a host

`nua/front.lua` builds Nua's host table:

- `typed_lambda`, `typed_function`, `struct`, `sum`: today's `G`, fed AST nodes instead of a
  token reader;
- `export`: today's macro, as a statement translator;
- `facts`: Nua words, externs, prelude arities (the Nua half of `application.lua`);
- `runtime`: the overrides of §4.5.

`nua.translate` becomes `mua.translate(src, path, nua_host)`; the loader's searcher and
`nua.prelude` keep their roles (the prelude puts `__mua` with Nua's overrides in the
environment).

## 7. The code split

| Today | Becomes |
|---|---|
| `macro.lua`, `macro/*.lua` (LuaMacro 2.5.0, Odding's LPeg lexer) | removed; `mua/lex.lua` is written fresh, not derived |
| `luam` | replaced by Mua's runner, `mua file.lua`: run, `-d` dump, `-e` expression, `--no-contracts` |
| LPeg (`make deps`, `tools/deps.sh`, `tools/doctor.lua`, `nua.lua`'s doctor line, README, `tests/build.sh`) | dependency removed |
| `THIRD_PARTY.md`, `COPYING` entries for LuaMacro, the lexer and LPeg | removed with the code (M3) |
| `macro/let.lua` | retired; its rules live in `mua/parse.lua` and `emit.lua`, its documentation in syntax.md |
| `macro/nua.lua` | retired: `.name` and spread move to the parser; the typed hooks become `nua/front.lua` |
| `nua/colon.lua` `rewrite`, `expand`, `contextual_with`, `typed_lambda` | retired: the parser owns the forms |
| `nua/colon.lua` `colonize`, `withize`, `foldends`, `inline_tables`, `mark_tables` | `mua/fmt.lua` printing choices |
| `nua/syntax.lua` `Reader`, `P` | `mua/parse.lua` |
| `nua/syntax.lua` `statement_calls` | retired: the emitter writes the calls |
| `nua/syntax.lua` `G`, `translate_*` | `nua/front.lua` |
| `nua/application.lua` generic analysis | `mua/scope.lua` |
| `nua/application.lua` Nua facts (`word`, `extern_fact`, `prelude_arity`) | `nua/front.lua`'s `facts` |
| `nua/fmt.lua` | `mua/fmt.lua` (parsing, printing, styles); `nua fmt` passes Nua's facts and host |
| `nua/fmt_cli.lua` | stays: the `nua fmt` command |
| `nua/stage.lua` `S.keyed` plain half, `S.keyed_table`, `S.spread_mark` | `mua/runtime.lua`; `S.keyed` keeps the record half as overrides |
| `nua/stage.lua` `S.contextual`, `S.open`, `S.oname`, `S.ocall`, `S.oset`, … | stay, as overrides of the runtime's entries |
| `nua.lua` `translate`, `prelude` | use `mua.translate` and install the overrides |
| `tools/tree-sitter-nua` | stays; its corpus is checked against Mua's cases |
| `tests/colon.lua` | Mua golden tests (`tests/cli.lua` (in the Mua repository)) |
| `tests/macros.lua` | replaced by the runner's tests (status codes, tracebacks, `-d`, `-e`) in `tests/cli.lua` (in the Mua repository) |

## 8. Acceptance

- The runner runs Mua programs with no host and no LPeg on the path: a test asserts no
  `nua.*` module is loaded and
  no `__S` appears in emitted Lua; structural types, `closed`, `required`, opening, spread,
  contracts (passing, failing with the right message and line, switched off), `struct`
  (construction checks, methods) and `oneof` (constructors, payload checks, matching with a
  missing or an unknown handler) are tested there.
- Golden tests per form of §3: source → Lua, lines and error positions included.
- The emitted Lua of every `.lua`/`.nua` file of the repository is checked against today's
  pipeline during the migration: the same text, or the same behaviour where the text
  differs (spacing, call grouping).
- Nua's suite passes unchanged: `make test`, `make test-native`, `make test-format`,
  `make test-tree-sitter`.
- Each surface rule exists once (§2, principle 4).
- The lexer: golden token tests (every literal form, long brackets, comments) and a
  byte-for-byte round trip of every repository source.
- The bytecode cache: a changed source, Mua, host or LuaJIT recompiles; a cached
  module's tracebacks name the source file and line.

## 9. Behaviour changes

- **Writes inside an opened Lua table.** macro.let sends every free-name write in a `do(..)`
  body to the opened table (`__newindex = home`). Under §4.4 a write goes to the table only
  for a name it introduces; any other name is written where Lua would write it. Nua's opened
  blocks already behave this way. No repository source depends on the old rule (to be
  confirmed by the comparison of §8).
- **Contextual `with` without a host** is a plain table (today it calls a `with` only Nua
  defines).
- **Typed forms without a host** have a meaning (§4.7, §4.8) where today they are errors or
  undefined names; no existing program is affected.
- Nothing else; any further difference found by §8's comparison comes back for a decision.

## 10. Steps

1. `mua/lex.lua`, then `parse.lua`, `emit.lua` and `load.lua` for host code (what steps
   1–3 and 5 do), compared with today's pipeline on every repository file.
2. `mua/runtime.lua` (spread, `with`, `define`, opening, structural markers, checkers,
   `struct`, `oneof`) and the emitter's contracts with their off switch; Nua's prelude installs
   its overrides; `S.keyed` keeps the record half.
3. The host interface; `G` moves to `nua/front.lua`, fed AST nodes; `macro/nua.lua`,
   `statement_calls` and colon.lua's `rewrite` are retired; `macro/let.lua` is retired.
4. `mua/scope.lua` and the Nua fact provider; `mua/fmt.lua`; the tree-sitter corpus
   check.
5. Remove LuaMacro, LPeg and their records (M3); the runner replaces `luam`; the bytecode
   cache; docs (syntax.md §2.4, architecture.md, AGENTS.md, README).

Focused checks in between (golden tests, `tests/colon.lua` until it is replaced,
`tests/macros.lua`, the rejection table, the formatter cases); the full suite once at the end.

## 11. Not in scope

A LuaJIT backend for Nua (E3, decided as a later milestone): the residual program of the
prepared IR written as Lua with FFI, JIT-compiled by LuaJIT, beside the C and libgccjit
backends; designed after this restructure.

Writing the compiler in Mua: the next design, which this one makes possible (`oneof`
and exhaustive matching for IR nodes instead of `op` strings, `struct` and closed structural
types for places, slots and summaries, contracts on its words, vocabularies instead of
file-level locals). Any change to what a Nua program means.

Pending from milestone 5 (change `suupxtvx`): checks for sum globals and call results built in
elements (`examples/nested_owners.nua`, the native tests); memory.md statuses (§6.3 rows
implemented, R3's wording on named pushes, §13); syntax §9.13's "Not yet"; architecture.md;
the handoff; one full-suite run.

## 12. Decisions

All taken 2026-11-04 (L1–L4 after checking the pinned LuaJIT, which carries LuaJIT 3.0's
syntax backport).

- **M1. Typed forms are Mua syntax with a default meaning.** Mua parses them; a
  host replaces their meaning (§5); without a host they are contracts (§4.7), `struct` and
  `oneof` (§4.8), with an off switch for the checks. Rejected: passing token spans to the host
  unparsed (two parsers would remain), and typed forms as errors without a host (Mua
  should be useful on its own).
- **M2. One parser,** built from syntax.lua's `P`, replaces macro.let's token marking and
  colon.lua's rewrites (§4.2). Rejected: keeping the token mechanisms (the duplicated rules
  would stay).
- **M3. LuaMacro and LPeg are removed** with their records: their entries leave
  `THIRD_PARTY.md` and `COPYING`; the lexer is written fresh, not derived. The project's
  GPL-3.0-or-later and Runtime Library Exception terms are unchanged. Loading is
  `loadstring` of emitted text, or cached bytecode (§4.3).
- **M4. Names (settled 2026-11-04 with the Mua name):** the layer is **Mua**, the language
  between Lua and Nua (Lua → Mua → Nua): `mua/` for the layer, `__mua` for its runtime in
  emitted code, `nua/front.lua` for Nua's host, `mua` for the runner (`mua file.lua`, replacing
  `luam`); Mua files `.mua`, Nua files `.nua` (Lua modules a Mua program requires stay `.lua`). The dependency rule: **Mua knows nothing about
  Nua; Nua knows about Mua**, through the host interface (§5) over Mua's AST, never by
  translating to Lua and reparsing. Mua is meant to be its own project later (after the
  restructure and its revalidation); until then it is the `mua/` directory.
- **M5. Opening writes follow the lexical rule** for Lua tables too (§4.4, §9): one semantics.
- **M6. `closed`, `required`, `optional`** are runtime words of Mua (§4.6), and closed
  structural types are checkers (§4.7).
- **M7. Order:** this design's steps (§10) now. Milestone 5's remainder (§11) waits: every
  step of it was tested as it landed, and the whole is revalidated once after this
  restructure, which has to validate everything anyway.

- **L1. Mua is the Lua we run on:** LuaJIT 2.1 with the syntax backported from LuaJIT
  3.0 (merged upstream 2026-07-20: short functions `|a, b| -> e`, `x -> e`, `|| -> e`,
  `|x| -> do … end`; `c ? a : b`; `?.` in all its forms; `??`; `! && || !=`; `~ & | << >> ~>>`;
  compound assignment `+= -= *= /= %= &= |= ~= <<= >>= ~>>= ..=`; `const`; `continue`; `_` in
  numbers; `0b` literals; `;;` anywhere; the line directive `# n "name"`). Mua lexes,
  parses and emits all of it verbatim, with LuaJIT's precedences. Not in LuaJIT 2.1, so not
  in Mua: `//`, `^=`, `??=`, `...name`.
- **L2. Where LuaJIT's syntax meets Mua's:** a `:` closes an open `?` (the ternary's
  middle operand takes no block colon and no method colon, LuaJIT's own restriction); a name
  followed by `->` always begins a short function, also as a juxtaposed argument
  (`map xs x -> x * 2` is `map(xs)(x -> x * 2)`); `|` and `||` begin a short function where an
  expression starts and are operators between operands; at the start of a statement, `const`
  and `continue` followed by a name (or `function`) are LuaJIT's declaration and statement,
  never a juxtaposed call; a `~=` statement is xor-assignment, `~=` in an expression is "not
  equal".
- **L3. Nua typed bodies:** the customary operators are normalized in the AST (`!`, `&&`, `||`,
  `!=` reach the host as `not`, `and`, `or`, `~=`). The ternary, `??`, `?.`, compound
  assignment, `const` and short functions inside typed bodies are a later Nua language
  decision; until then the Nua host rejects them in typed bodies with a message naming the
  form.
- **E1. Lean emission.** The emitter allocates nothing per access and emits no closures of its
  own; what the runtime does is paid where a value is built (a keyed spread, a `struct`
  construction, a contract check), never per name access. Opening compiles to locals: each
  opening is `local names, ctx = __mua.open(v)`, and a free name reads through a
  ternary chain over the openings newer than its nearest binding,
  `(names2.x ? ctx2.x : names1.x ? ctx1.x : x)`; a write evaluates its value once and
  assigns through the same chain. A host replaces `open` (Nua: names and a proxy for records
  and methods); the emitted shape does not change.
- **E2. No FFI-backed `struct` in Mua:** cdata cannot hold Lua values, so a layout in C
  types is Nua's native world, not Mua's.
- **L4. Both lambda spellings stay:** `do(x) = e`, `do … end` and the colon form (Mua's,
  and the only spelling of typed words `do(x: T): R`), and LuaJIT's short functions.

Corrected while recording: matching was first proposed to check exhaustiveness once per
handler table; a handler table is built anew at each match, so the check runs at every match
(one walk over the alternatives), §4.8.
