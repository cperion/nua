# Mapping the compiler before rewriting it

**Status: source-reading map and design questions, not a replacement architecture.**
This records Nua at `6f47a4bb`, with Mua pinned to `f74545c`. It applies Part I
(especially §2 and §4.5) of Mua's [compiler guide][guide]: identify the
representations, the operations over them, and what survives each boundary.

[Syntax][syntax] remains the language/ABI authority; [architecture][architecture]
remains the compiler/runtime authority. Sections 1–6 below describe inspected
implementation. Section 7 proposes organizing principles for discussion; none is
an implemented change. The test references are witnesses to read, **not fresh
pass results**. This mapping did not run the compiler acceptance suites.

The subsequent [rewrite inventories](compiler-inventory/README.md) are the curated
review surface: they organize this evidence around application, evaluation,
residualization and materialization, and record additional probes and freeze
requirements. This map remains the earlier source-reading narrative.

The reading follows the main driver, front end, evaluator, memory integration,
shared preparation and C/libgccjit boundaries. It is not a line-by-line audit of
all primitives, runtime policy, foreign-header processing or experimental backends.

## 1. The actual pipeline

```text
source + Mua parse host
    │ Mua parser; nua.front supplies export/call and typed-form meanings
    ▼
Mua AST
    │ Mua emitter + nua.front code generator
    ▼
staged Lua text
    │ loadstring + Nua prelude + compilation-scoped require
    ▼
Lua closures, native types, words, host values
    │ application executes staged closures
    │ known computation disappears; effects/dynamic work produce commands
    │ places, borrows and owner placement participate during evaluation
    ▼
residual module: functions + exports + externs + summaries
    │ attach lazy runtime definitions when needed
    │ shared preparation (currently in nua.cgen)
    ▼
prepared reachable program + storage layouts + stack/call metadata
    ├── C text → external C toolchain
    └── libgccjit construction → object or in-process code
```

This is not a simple one-way sequence of pure passes:

- **Specialization is execution**, not a later optimizer walking the source AST.
  The front end stages comparisons, control flow, mutation and returns that Lua
  cannot supply through ordinary operators alone.
- Creating a function can recursively create other functions. Repeated keys,
  changed arguments under dynamic control, owner-result placement and recursive
  move summaries can force different kinds of retry.
- Reaching a runtime symbol can materialize its Nua word while finding reachable
  functions. The runtime is compiled through the same machinery, not pasted in as
  an opaque implementation of library algorithms.
- Ownership is not merely a validation pass after specialization. `memory.lua`
  adds methods to the evaluator's `Builder` and wraps `Builder:sub` to close
  block-owned storage.
- `nua.compile(..., { no_c = true })` returns the staged module before C emission
  and shared preparation. Returning a module is not proof it has passed the
  whole-program checks in preparation.

**Source anchors:** [driver] `nua.compile`, `nua.attach_runtime`; [front]
`M.host`, `G:lambda`, `G:function_body`; [stage] `invoke`, `Builder:apply`,
`build_function`; [memory] `Builder:sub`; [cgen] `reachable`, `G.prepare`;
[jitgen] `JG.build`.

### Compilation scope is a separate boundary

[loader] `with_context` temporarily replaces Lua's loaded-module table, loader
list, preload table and paths, restoring them on success or failure. Existing
host modules are shared; newly loaded program modules belong to that compilation.
It rejects nested entry: the evaluator currently has one active compilation.

Compiler modules retain host lifetime. `S.reset` creates a new residual module;
it does not rebuild the compiler's type universe or undo arbitrary host effects.
`native(word)` constructs an export view inheriting the parent module's definitions;
that view needs its own preparation/layout proof. Compiled native results can
outlive the compilation that produced them.

## 2. Representations: data, identity, and mutable attachments

There is no central residual-IR schema today. The main discriminants are `k`
(values and syntax), `pk` (places), `op` (expressions/statements) and `kind` (types,
tokens and other descriptors). Equal spellings across domains do not make them
one family.

| Representation | Current shape and creator | Important identity/lifetime property |
|---|---|---|
| Source syntax | Mua's tagged AST; Nua adds `export` and application `boundary` metadata | Owned by the front-end translation; no Lua-text reparse into a second AST |
| Staged body | Generated Lua closure in a word/callback descriptor | Executed again during specialization retries; captures ordinary Lua upvalues |
| Native type | `Type` metatable, `kind`, layout/element/field information in [types] | Parameterized types are cached; declared records have distinct identities; methods/hooks can be decorated for a compilation |
| Word | `W`: identity, parameters, result type, body, supplied arguments | A partial application shares identity/body but has its own supply |
| Callback | Ordinary Lua closure registered with a staging descriptor | Invocation options and return inference belong to the call, not an ambient “next callback” flag |
| Staged value | `V`: native type plus a tagged payload | Can also carry borrow provenance; not every value is a residual expression |
| Place | `P`: type, storage/projection identity, parent/owner information | Shared by state maps and expression reads; deep copying would destroy aliases |
| Abstract store | Table keyed by place, with pending/materialized/uninitialized entries | Forked shallowly for branches; joined with possible writes into predecessor blocks |
| Borrow provenance | Tokens or a set of tokens, attached to values/places | Compiler information, not extra native ABI fields; tokens can be ended/restored |
| Expression | Plain `op` table, usually typed, referencing places/types/functions | Expression children can be copied while those identity-bearing references remain shared |
| Block/command | Ordered list of `op` tables, some with child blocks | Mutable during staging and preparation; not all commands pass through `Builder:emit` |
| Function | Descriptor with parameters, locals, body, status and derived summaries | Registered while still building so recursive applications can refer to it |
| Module | Function/export/extern registries, keys, names, counters and later preparation data | Compilation-owned; an export view can share definitions but not its layout proof |
| Frame/signal | Evaluation frame plus Lua-error control signals | Staging control only; neither is residual control flow |
| Owner slot/placement | Records of stacks held through a place; allocation-ordinal placement plans | Slot records belong to holders; moves transfer ownership, not the slot record itself |

### 2.1 Staged values are richer than Known/Dynamic

[stage] defines these value tags:

| Tag | Payload/meaning |
|---|---|
| `known` | Typed scalar/host representation in `v` |
| `dyn` | Residual expression in `e` |
| `agg` | Field-wise staged values in `f` |
| `ref` | Handle to a native place |
| `sumv` | Known alternative, payload of any binding time |
| `array` | Immutable sparse contents from [array-values], including a default value |
| `array_ptr` | Deferred pointer into an array place, with offset and builder |

[memory] adds `fresh`: an owner-construction recipe, consumed by in-place
initialization rather than ordinary scalar reification. Known text uses existing
aggregate/pointer representations plus [strings] `known_text`, not a separate
`known_string` value kind.

`is_known` and `static` answer different questions. A value may contain known
contents but still borrow storage; `static` excludes borrowing values from partial
application and specialization-key capture. Plain host values are a separate
input domain, not silently all `Known` native values.

The private `Matched` result, packs, contextual initializers, opened contexts and
select-case descriptors are additional staging objects. Do not force them into
`Value` merely because the evaluator can return or inspect them.

### 2.2 Places are identities, not just address expressions

Observed forms include `local`, `field`, `deref`, `index`, `temp`, `lv`, `rvar`
and captured `param` places. Traversal/backends also understand induction-variable
places (`iv`). `moved` places are private path-fact markers, including held marks:
they never denote native storage.

Place attachments matter as much as the tag: cached field projections, array
projections, checked lookup descriptors, frame/block ownership, escape marks,
stored borrows and container ownership. `S.checked_place` is currently a decorated
`deref`, not an independent place kind. Globals are accessed through global-address
expressions and pointer places; a check for `pk == 'global'` alone is not evidence
of a constructor for such a kind.

The distinction to preserve is **place identity / address calculation / path
knowledge about contents**. These are related, but they are not interchangeable.

### 2.3 Residual vocabulary, grouped by responsibility

This groups inspected constructors and consumers; it is a navigation inventory,
not a claim that every tag below has the same legal fields in every phase.

| Domain | Representative current operations |
|---|---|
| Values and storage | `const`, `zero`, `null`, `param`, `read`, `addr`, `gaddr`, `field`, `array_index`, `agg`, `array`, `sum`, `tagname` |
| Computation | `bin`, `cmp`, `un`, `and`, `or`, `conv`, `vaconv`, `sizeof`, `cconst` |
| Calls | `call` (native function or extern), `calli`, `fnaddr`, `rtcall` |
| Stack/task support | `stack_index`, `res_index`, `task`, `ops`, `slot_at`, `atomic`; blocking-wait placeholders `block_fn`, `block_env` |
| Commands | `store`, `let`, `expr`, `setparam`, `if`, `loop`, `for`, `ret`, `goto`, `label`, `break`, `wait`, `spawn`, `fence`, `trap`, `gs_reset`, `nop` |

There are important phase distinctions already hidden in these tables:

- `nop` can be a **patch point** for a lazy read snapshot, deferred return value
  or immediate-match payload. Cleanup later removes remaining no-ops.
- Shared preparation inserts stack-reset commands and task-yield waits.
- `walk_block` synthesizes `place` expressions for destinations. That is a walker
  protocol, not an expression emitted by the native backend.
- Blocking placeholders are interpreted in a wait's specialized lowering.
- A function's type, ownership summaries, stack requirements and backend planning
  fields are currently accumulated on the same descriptor.

A future schema must distinguish phase-valid data from traversal conveniences and
unfinished construction. Renaming all `op` strings would not establish that.

### 2.4 Source provenance is not yet a uniform node field

Mua nodes carry source lines. `G:at` preserves line alignment in generated Lua;
words/callbacks retain locations, and `S.fail` uses the Lua stack and active frame
trail to locate errors. Emitted command IDs and size-profile attribution serve a
different purpose. Residual nodes do not uniformly carry the guide's `at` field.
A replacement needs an explicit provenance policy across closure execution and
retries, not just a field added to constructors after diagnostics are designed.

## 3. Operations: result, effects, and ordering

| Operation | Primary result | State it observes or changes | Current implementation |
|---|---|---|---|
| Translate typed syntax | Lua text/closures | Lexical scopes, openings, regions, loop bindings, output position | [front] `G:expr`, `G:stat`, `G:loop_state` |
| Normalize application syntax | Proven argument-group normal forms | Lexical facts; no program execution | [application] over Mua's `scope` |
| Construct/coerce native values | A staged value or place | Can consult hooks, resolve places, create storage | [stage] `coerce`, `value_of`, callable `Type` |
| Fold native scalar operations | Target-correct known value or diagnostic | Numeric type rules, not unrestricted Lua arithmetic | [fold] `binary`, `unary`, `compare`, `convert` |
| Read/write/bind | A value, or updated contents | Abstract store, versions, borrow validity, lazy snapshots, emitted commands | [stage] `Builder:read`, `store`, `bind` |
| Reify a value | Residual expression | May escape/materialize a place, resolve a lookup or signal loop restart | [stage] `ex` |
| Emit a command | Appended command | Read-version validation, expression ownership, profiling stream | [stage] `Builder:emit`, `copy_expr` |
| Fork/join control flow | Blocks and merged state | Path facts, pending stores, owner releases, dead paths | [stage] `Builder:sub`, `join`, `S.if_` |
| Apply a word | Value/place/staging result | Coercion, static supply, active keys, frames, memoization, function construction | [stage] `h.apply_word`, `Builder:apply` |
| Evaluate/retry a frame | Result or next attempt | Return sites, widening, loop variables, snapshots, ownership | [stage] `run_frame`, `run_inline`, `run_loop` |
| Finish returns/matches | Joined result | Payload capture, predecessor stores, handler landings, borrow union | [stage] `return_value`, `finish_frame`, `h.land_match`, `h.finish_match` |
| Cross a function boundary | Call result plus summaries | Address escape, moved owners, result storage, borrow/shrink effects | [stage] `build_function`, `emit_call` |
| Manage owner storage | Ownership/placement and residual operations | Claims, block-owned slots, arena events, result placements | [memory] `gs_alloc`, `adopt_owner`, `move_owner`, `gs_close` |
| Capture/spawn/wait | Task descriptor or wait result | Copyability, parent values, checked-lookup epochs, suspension metadata | [stage] `spawn_block`, `capture_read`, `capture_leaves`, `wait_op` |
| Prepare a residual module | Reachable functions and prepared metadata | Graph-wide checks, cleanup, layouts, stack planning and exit rewrites | [cgen] `G.prepare` |
| Lower to a backend | C text or gccjit unit | Backend names, declarations, types, labels, task frames | [cgen], [jitgen], [cjit] |

**Reification is not pure.** For example, `ex(ref(place))` can expose the address
and make the local ordinary storage. A reference to a loop-round copy can signal
that the original local must be adopted and the loop retried. A future pass
signature must admit these effects rather than concealing them behind a function
named “convert”.

**Traversal edges are not all structural children.** Expressions refer to types,
places, externs and functions. Following every Lua table field recursively would
traverse shared graphs, not just the expression tree. Current walkers explicitly
exclude identity edges or visit address computations hidden in places. Those
policies need named contracts, including traversal order when work can emit code.

## 4. State by role and lifetime

The guide's inherited/accumulated/evolving/produced roles apply to an operation,
not forever to a table. A function body is produced by staging, then read and
rewritten by preparation. The rows below identify responsibilities; they do not
propose a universal context object.

| Lifetime / owner | State today | Role in the owning operation | Boundary policy observed |
|---|---|---|---|
| Compiler host | Type interning, compiler modules, callback registry, backend/FFI state | Shared identities and capabilities | Survives a compilation; compilation-specific library words must not be reused accidentally |
| Compilation | `module.functions`, key maps, exports, externs, names, `uid`, `version` | Registries/results plus fresh-name/version capabilities | Created by `S.reset`; not generally rolled back with a frame |
| Front-end body | `scopes`, `region`, `loops`, `parent`, application facts | Inherited bindings plus evolving translation state | Push/pop scopes; save/restore body and output buffers around nested translation |
| Function builder | `fn`, `block`, `state`, `dead`; `active`, `frames`, `regions`, `depth` | Produced code, evolving facts, active evaluation stack | A materialized function gets a fresh builder; in-place calls use the caller's builder |
| Path | Place entries, range facts, `path`, moved/held markers | Evolving knowledge | Branches start with shallow copies; joins decide which facts and storage survive |
| Invocation/frame | Arguments, key/shape, mode, return sites, widening, inferred result, match landings | Inherited arguments plus produced result/control state | New frame for each attempt; completion, tail round and restart differ |
| Lazy bindings | `lazy`, frame registrations, holes and copied read nodes | Deferred construction obligations | A later write can fill the earlier hole; frame expiration unregisters bindings |
| Borrow tracking | Tokens, stored views, frame-token lists, `shrink_log` | Lifetime facts and undo information | End at relevant owner/activity/frame boundaries; logged endings can be undone on retry |
| Storage planning during evaluation | `gs_live`, `gs_claims`, `gs_owned`, `gs_extra`, `gs_res_slots`, `registered` | Evolving holdings, block-owned cleanup obligations | Release/adopt/move per path; snapshot handles selected holdings |
| Placement discovery | Allocation ordinals, arena events, result/arena allocation plans | Ordered evidence and cross-attempt feedback | Function rebuild can carry a revised placement plan |
| Checked lookup reuse | `ccache`, `cepoch`, `path` | Cache with explicit validity conditions | Reuse only on a compatible path/epoch; calls, loops, waits and rollback can invalidate |
| Statement attribution | Global emitted stream, builder emission indices, size profile | Accumulated diagnostic/profiling output | Retry marks abandoned positions `false`; surviving nested functions keep their positions |
| Shared preparation | Reachability, global-effect facts, storage layouts, stack graph | Produced analyses and IR rewrites | Per exact module/export view; source types keep their declared fields |
| Backend unit/function | Type maps, names, declarations, labels, task frame plans | Produced backend representation | Separate from staging attempts; compiled results have their own lifetime |

Two easily missed distinctions:

1. A **native owner** concerns the residual program's storage. Ownership of a
   compiler table/list concerns who may mutate or retain that representation.
   The rewrite must describe both without confusing them.
2. A shallow copy shares identities and mutable attachments. It is not a complete
   speculative transaction, and Mua's spread will not turn it into one.

## 5. The boundaries that define the specializer

### 5.1 Supplying arguments versus evaluating a body

`h.apply_word` coerces supplied arguments. With too few arguments it constructs
another word with a static supply; it does **not** execute the body. Saturation
calls `invoke`, which chooses entirely compile-time evaluation or the current
builder's application path. Chains can collect a complete supply before that
check, so transient dynamic arguments need not become stored partial applications.

All known inputs can compute to a known result. A saturated call with dynamic
inputs executes the same staged closure, producing its residual work. These are
different boundaries; “partial application” must not be used to mean both.

### 5.2 Dynamic branch: fresh code, forked facts, shared identities

`S.if_` selects only one closure for a known condition. For a dynamic condition it:

1. Takes the current place-state map as the base.
2. Runs each arm through `Builder:sub`, with a fresh block, shallow state copy,
   branch facts and distinct path identity.
3. Emits an `if` containing those blocks.
4. Joins the surviving arm states.

The join can append stores **to the arm blocks already attached to that `if`**.
If a place escaped on one path, other paths must materialize their own pending
contents. If an owner moved on only some paths, other live paths release what
they still hold. Zero live paths make the continuation dead; one live path can
supply its state directly.

Thus a branch's output is not just `code`: it includes end state and reachability,
and its code remains available for reconciliation. [memory]'s `Builder:sub`
wrapper also closes block-owned slots on normal completion. A speculative signal
is handled by the enclosing retry protocol, not by assuming every callback ran
its ordinary block-end cleanup.

### 5.3 Inline return and immediate match: the invocation owns its exits

An inline frame can return directly or collect several dynamic return sites.
`finish_frame` temporarily removes each return jump, performs the join (which may
write predecessor stores), and puts the jump back. Only then are separately
staged handler sections spliced into the containing block.

For immediate matching, `matched_return` captures payload expressions before
return-path stores. Known alternatives get their own landing groups; equal known
payloads can remain static, differing payloads need a result slot. Producer-state
joins and handler-result joins are separate. A nested application must not borrow
another invocation's handler continuation.

### 5.4 Tail round, generalization and rollback

Frames run in inline, loop, root-function or compile-time modes. A known tail
round can trampoline with new arguments. Under dynamic control, changing known
arguments are widened and an attempt is replayed. Residual loops use explicit
state parameters, with machinery to adopt locals written through aliases and to
preserve invariant record fields.

`Builder:snapshot` / `rollback` form a **selective undo protocol**, not a deep
copy of the compiler:

| On frame rollback | Current handling |
|---|---|
| Active output | Restore the block and truncate commands to its saved length |
| Abstract contents/reachability | Restore a shallow state copy and `dead` |
| New locals | Truncate this function's locals to the saved count |
| Attributed commands | Clear this builder's abandoned statement graphs, leaving stable stream positions |
| Escaped locals | Undo escape marks logged after the snapshot |
| Borrow endings | Undo later `shrink_log` endings and restore their holder fields |
| Stack holdings | Restore saved live/claim/extra/result sets, remove later registered slots, restore the current block's owned list |
| Checked lookups | Advance the epoch rather than resurrecting old cached lookup results |

Frame/region/active-key stack unwinding and lazy-binding expiration are managed
around body execution, not solely by `rollback`. Independently materialized
functions and monotone ID/version supplies are not discarded by this frame
rollback.

**Audit question, not a diagnosed defect:** allocation counters, arena-event
history, function summaries and several place/token attachments are outside this
snapshot's field list. Before replacing the protocol, classify each as deliberate
conservative evidence, monotone capability, separately managed state, or something
that must be restored. “Copy the builder with spread” cannot answer that question.

### 5.5 Materialized call and function rebuild are different boundaries

Exports, explicit `call`, recursive keys, function pointers/native entry points
and spawned tasks can require residual functions. `build_function` registers a
building descriptor, creates a fresh builder, substitutes dynamic parameters and
stages the body. Recursive references can encounter that unfinished descriptor.

`emit_call` does not carry the caller's whole abstract store into the callee. It
materializes escaping references, moves/adopts owners, reserves result storage,
and applies callee summaries about borrowed results, cleared contents and moves.
Some unfinished summaries use conservative assumptions; recursive moves can
require rebuilding once the initial assumption is disproved.

`h.build_with_moves` handles function-level retries for moves/results/arena
placement. It removes functions built since that attempt's start from the
function list and key maps, then rebuilds with feedback. This is intentionally
broader than a frame rollback, which preserves separately built functions.

### 5.6 Task and blocking boundaries

A spawned body gets a separate resumable function. Known captures are baked in;
dynamic captures are checked for sendability and copied from the parent at spawn.
Captured array views are rebased onto the task's own copy, not the parent's place.
`capture_leaves` also rewrites foreign expression leaves discovered in residual IR.

A blocking body inside a task is different: it uses the suspended task's frame.
It becomes a wait with a nested body and backend placeholders for a blocking
function/environment. Outside a task the body runs in place. A generic “nested
function” transformation must not conflate these capture contracts.

### 5.7 Preparation: graph-wide knowledge before backend lowering

`G.prepare` currently performs this ordering:

1. Find reachable functions, lazily resolving runtime definitions where needed.
2. Consult the exact view's preparation cache; avoid parameter/function C-name
   collisions for the functions being prepared.
3. Check task-global effects on the complete reachable graph **before cleanup**
   can erase address-provenance evidence.
4. Run cleanup on functions. It is a fixed ordered sequence guarded by `fn.cleaned`,
   not the guide's structural-equality fixed-point optimizer.
5. Analyze module-local storage layouts without changing source type fields.
6. Plan data-stack requirements, recursive call bases and result-region offsets.
7. Insert task loop yields and stack restoration at exits for unprepared functions.

[task-globals] already uses a monotone fixed point, separating task/plain call
contexts while sharing global cells. [layout] computes private record storage
conservatively, pinning ABI-visible/address-observed layouts. These are different
analyses with different state, not one generic optimizer context.

Preparation mutates existing function bodies/metadata. C and libgccjit both use
it; it happens to live in the C emitter module. The experimental/deprecated direct
backend is another consumer to inventory, but architecture §11 explicitly says
it retains declared record layouts. No backend removal is implied here.

## 6. Existing witnesses and mismatches to keep visible

### Test/source reading map

These are starting points for the corresponding contracts, not a command list
for an expensive validation campaign.

| Obligation | Existing witnesses |
|---|---|
| AST-to-staged-Lua translation, application grouping | `tests/front.lua`, `tests/formatter_application.lua`, `examples/spec_core.nua`, `examples/boundary.nua` |
| Value contents, immutable array updates | `tests/array_value.lua`, `examples/staged_values.nua` |
| Alias-written loop state and invariant fields | `tests/loop_adoption.lua`, `examples/loop_adoption.nua` |
| Retry graph retention and local lifetime identities | `tests/staging_retention.lua` |
| Immediate-match payload/state joins | `tests/immediate_matches.lua`, `examples/immediate_matches.nua` |
| Borrow propagation and boundary rejection | `tests/borrowed_views.lua`, `tests/errors.lua` |
| Owners, nested placements and storage | `examples/nested_owners.nua`, `tests/map_types.lua`, `tests/errors.lua`, `tests/fuzz/storage.lua` |
| Layout proof versus export view/foreign ABI | `tests/storage_layout.lua`, `tests/storage_boundaries.lua` |
| Task-global effects across aliases/calls | `tests/task_globals.lua` |
| Compilation/module lifetimes and failure restoration | `tests/modules.lua` |
| Native numeric agreement and specialization | `tests/fuzz/fuzz.lua`, `examples/spec_core.nua` |

Future focused checks should exercise representations and state obligations
without repeatedly compiling the entire runtime/library corpus. End-to-end
C/JIT checks still belong at coherent implementation milestones, not after every
helper. No fresh runtime or backend agreement is claimed by this document.

### Documentation shorthand versus source

- Architecture §5.1's “only two” reasons for a function boundary is incomplete;
  §5.7 and `Builder:apply` already implement explicit `call`. Native/function-pointer
  entry and task construction also deserve distinct entries in an implementation map.
- The four-form value sketch in architecture §3 is conceptual, not the current
  complete value vocabulary (§2.1 above).
- `memory.lua`'s opening comment says resizable values cannot be assigned or
  returned; its current move/result implementation and the later memory design
  are substantially richer. The opening comment is not the contract.
- The pipeline drawing's “prepare after residualization” does not imply that all
  lifetime/ownership work happens there; much of it is embedded in staging.

These observations are recorded rather than silently rewriting the specification
or inferring a new semantics from a stale comment.

## 7. Design implications to discuss next

These are **proposals**, not decisions about files, public APIs or implementation
order.

### Closed representations, open operations

Use Mua families for actual closed domains, beginning the design with staged
values, residual expressions and commands. Places also need explicit shapes,
but addressable places and path-only markers should be distinguished deliberately.
Native type kinds can be closed while library owner declarations and user-defined
methods remain open extension points. Not every compiler object belongs to one
large family.

For each operation, state its result and effects before choosing handlers. A
knownness query, an expression copier, a reifier and a dependency collector do
not share a result contract just because they visit some of the same shapes.
Explicit identity/no-contribution vocabularies can be composed by spread; unknown
kinds should fail coverage checks rather than receive a permissive fallback.

### Explicit boundaries, not a larger context abstraction

Design named operations for branch evaluation/reconciliation, frame completion,
retry, materialization and function rebuild. Each needs a small boundary table:
what is inherited, shared, reset, accumulated, produced and undone. Keep fresh
identities and graph registries separate from rollback-owned path state.

Treat unfinished blocks/patch points as construction state with a completion
boundary. The guide's “a rewrite owns its output” is a useful target, but current
joins intentionally patch predecessor blocks. Choose how to represent that
obligation; do not merely declare the current IR immutable.

### Preserve the online evaluator

Mua parses Nua already. We do not need another parser, nor a second source AST
just to make the rewrite resemble the guide's Lisp. Staged closures can remain
the execution engine while values, residual data, analyses and boundary protocols
become explicit. Keeping emitted Lua versus constructing closures directly is a
separate architectural choice, not a prerequisite for using families and passes.

Keep expressible library/runtime algorithms in ordinary Nua. Rewriting the host
compiler in Mua is not permission to pull those algorithms back into compiler
handlers. Mua remains independent of Nua.

### Separate shared preparation from backend spelling

Make the prepared-program contract explicit before moving `G.prepare`. It must
include whole-program checks, layouts, stack/exit obligations and task suspension
support. C and gccjit consume that common contract; neither should acquire its own
specialization or ownership semantics during the rewrite.

### The next design exercise

The [inventory scenarios](compiler-inventory/review.md) now carry this exercise
forward. The original plan was:

Take one ordinary word with a dynamic branch and a mutable local, then one with
an alias-written loop and one with an owner result. For each, draw:

1. the value/place/command shapes it actually needs;
2. the operation results and effects;
3. the branch, call and retry boundary tables;
4. who owns incomplete output and when it becomes ready for preparation;
5. the focused evidence that would catch a wrong design.

Agree those contracts before selecting the first end-to-end implementation
milestone. A file split or syntax conversion by itself is not that milestone.

[guide]: https://github.com/cperion/mua/blob/f74545c99f429da4bfe169d32012e6f62e6bf367/docs/writing-compilers.md
[syntax]: ../syntax.md
[architecture]: ../architecture.md
[driver]: ../../nua.lua
[front]: ../../nua/front.lua
[application]: ../../nua/application.lua
[types]: ../../nua/types.lua
[stage]: ../../nua/stage.lua
[memory]: ../../nua/memory.lua
[array-values]: ../../nua/array_value.lua
[strings]: ../../nua/strings.lua
[fold]: ../../nua/fold.lua
[loader]: ../../nua/loader.lua
[cgen]: ../../nua/cgen.lua
[jitgen]: ../../nua/jitgen.lua
[cjit]: ../../nua/cjit.lua
[layout]: ../../nua/layout.lua
[task-globals]: ../../nua/task_globals.lua
