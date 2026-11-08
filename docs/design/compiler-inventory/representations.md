# Representation inventory

Part of the [review candidate](README.md). **Observed layouts are crosswalks, not
proposed Mua structs.** “Closed” below describes a domain whose operations must
account for all alternatives; it does not imply the current tables enforce it.

## Domain register

| ID | Representation; why it exists | Producer → consumer | Identity and disposition |
|---|---|---|---|
| R01 | Mua syntax, lexical/application facts | Mua parser and `application.analyze` → `front`/formatter | Mua-owned shapes; keep one AST, not a copied Nua syntax hierarchy |
| R02 | Source origin, application trail, attribution | Parser lines, `G:at`, word/callback locations, `S.site` → diagnostics/profile | Source identity differs from command identity; recommended explicit origin on produced residual work |
| R03 | Native type graph | `types`, owner declarations, foreign declarations → coercion, folding, storage, ABI | Shared identities; 19 current `kind` spellings below; methods/hooks are an open vocabulary |
| R04 | Word, requirements and supply | `S.word`, partial application, bound methods, `S.boundary` → application | Stable word identity across copies; native functions are not part of its definition |
| R05 | Host/staging inputs | Lua; contextual/opened/keyed/pack/callback machinery → application/coercion | Separate input domains, not miscellaneous native value kinds |
| R06 | Staged native value | Smart constructors, reads and operations → evaluation/reification | Closed semantic variants; borrow annotations and some deferred reads make these more than immutable constants |
| R07 | Native place | Locals, projection, reference reconstruction, capture → contents/read/address/store | Alias identity must survive structural rewrites; path markers are not addressable places |
| R08 | Abstract contents and path facts | Declare/read/store/branch → evaluation and reconciliation | Map keyed by place identity; entries replaced, not a cloned native heap |
| R09 | Residual expression | Evaluation, storage integration, preparation → traversals/backends | Structural children plus explicit identity edges; fields/phase rules below |
| R10 | Residual command/block | Emission, joins, completion, preparation → analyses/backends | Ordered work; construction-time patch points are not finished instructions |
| R11 | Construction obligations and exits | Bind, return, match, branch, loop → owning evaluation's completion | Hole/read registration, predecessor block, payload and end-state belong to a bounded activity |
| R12 | Evaluation/rebuild outcomes | Return/tail/restart/rebuild/error → designated driver | Closed protocol with destinations; not residual jumps and not ordinary user data |
| R13 | Borrow provenance | Activity/place/argument/element borrowing → lifetime and boundary checks | Tokens are identities; unions are sets; no native ABI payload |
| R14 | Storage holdings and placement | Generic memory integration → moves/releases/call planning | Slot identity differs from stack storage and holder identity |
| R15 | Materialized function and summaries | `build_function` → calls, preparation, backend | Register identity before body completion; descriptor currently mixes phases |
| R16 | Compilation module, export view, prepared program | Reset/export/runtime attachment/preparation → driver/backends | Exact export view owns its proof; definitions may be shared |
| R17 | Task/wait/select descriptions | Scope/spawn/first-of/I/O staging → residual control/capture/lowering | Task owns copied captures; blocking body borrows suspended task frame |
| R18 | Backend and external artifacts | Prepared program and header/platform inputs → C/object/native handle | Backend-local identities and resources, never a second specializer |

## R01–R05: inputs and identities

**R01.** `front.lua` consumes Mua expression/statement nodes and typed forms.
Nua adds `export` nodes and `boundary` application metadata. Facts from
`application.lua` prove native-word grouping without executing the program.
Source binding kinds, opened names, loop slots and body regions are translation
state, not native storage. The AST contract stays with the pinned Mua host API.

**R02.** Current provenance is line-aligned generated Lua, `loc` on words/callbacks,
stack inspection and active-frame trails. Runtime wait sites intentionally prefer
an entry-program call site over a library wrapper. `stmt.id`, `stmt.module` and
backend line counts are attribution, not source spans. Synthetic code needs a
named originating operation; it must not invent a source line. Full span/source-map
redesign is not implicit in adding Mua families (D04).

**R03.** All types have a display spelling; neither it nor optional `name`/`cname`
is an identity key. Parameterized types are cached, declared records are nominal, and sum
interning verifies payload type identity even when display strings match.

| Current kind | Semantic payload / invariants |
|---|---|
| `int`, `float` | Width; signedness for integers; target numeric rules. `Duration` is a distinct integer type, not a new kind |
| `bool`, `unit`, `cstr` | Boolean, no native payload, C string pointer respectively |
| `opaque` | Foreign name; no by-value construction |
| `ref`, `ptr` | Element type; checked native reference versus raw pointer contract |
| `id` | Element identity and library-defined native representation; not ownership |
| `owner` | Family declaration, element, optional key/length; `resizable`; library describes header/stacks/operations |
| `struct` | Ordered fields, field index, declaration identity; incomplete only while declaring recursive pointer shapes |
| `sum` | Canonically ordered alternatives, payload types and tags; may hold owners |
| `fn` | Parameter types and result; native function pointer ABI |
| `atomic` | Admitted element type; never an ordinary copyable local value |
| `array` | Element and positive known length; raw header arrays have a separate admission rule |
| `chan`, `pool`, `slot` | Element type plus sendability/ownership constraints |
| `group` | Internal task-scope handle; not a user-constructible native value |

`Slice`, mutable slices, `Str`, short text, foreign records and library records are
represented by existing kinds plus declarations/metadata. The library extension
point is open; do not introduce a compiler kind per container family. Derived
storage layouts are module-owned, not edits to the source type's fields.

**R04.** Current word fields are `id`, `name`, `params`, `ret`, `body`, `supplied`,
`loc`, `rest`; wrappers also carry receiver/boundary/inference/task information.
A requirement is typed or compile-time-only. A partial word shares body/identity
and owns its supply; its body has not run. A saturated invocation has an evaluation
lifetime separate from the word. A specialization key and an argument shape are
different representations: the key includes known values; the shape supports
recognizing generalization opportunities. Neither is a native signature.

**R05.** Preserve these distinct inputs/protocols:

- Ordinary host values and closures, including native type values and generators.
- Callback closures registered with a descriptor, executed in place with result
  inference and invocation-owned options.
- Immutable ordered packs (`Pack.c`), explicit expansion and rest requirements;
  packs cannot silently become native aggregates or multi-value word returns.
- Contextual initializers (`Contextual.fields`), which require an expected type.
- Keyed/spread entries and private spread marks; opened contexts with lexical
  shadowing; these supply names/data, not residual instructions.
- Extern descriptors (`cname`, parameter types, result, variadic/header/variable
  attributes); native globals with linkage, initialization, TLS/shared/owner policy.

A diagnostic inspector may print an opaque host identity. A serializer may not
pretend a closure's upvalues are a closed, pure compiler representation.

## R06: all current staged-value tags

Every row has `T`; optional provenance (`view`, captured reference tokens) is
compiler information. Identity references must not be recursively cloned.

| Tag | Payload | Knownness / consumers | Reification |
|---|---|---|---|
| `known` | `v` in native scalar/host representation | Known; target-aware equality/folding | `const` |
| `dyn` | Expression `e` | Not known; bind/read/version machinery | Existing expression, after view check |
| `agg` | `f`: declared-field → staged value | Field-wise knownness; text has a special known-text query | Aggregate, or whole-place read when justified |
| `array` | Persistent sparse `contents`: default, items, count | Element-wise knownness; immutable update/equality | Sparse `array` expression |
| `ref` | Place identity | Never static supply; can expose target and borrow provenance | Address; may flush storage/resolve lookup/restart loop |
| `sumv` | Known alternative `tag`, optional payload `p` | Payload determines knownness; Unit has no payload | `sum` with known alternative |
| `array_ptr` | Array place, offset value, originating builder | Deferred access to current staged array contents; not itself known | Escape array, indexed address |
| `fresh` | Owner type; construction recipe | Created by `memory.lua`; consumed in-place | **No general expression**; initialize/adopt into a destination |

`is_known`, `static`, equality, copying, binding and reification are different
operations. Identity equality is a valid fast path, not permission to compare
arbitrary table graphs. `same_value` compares dynamic values by expression identity;
its scalar case uses `fold.identical` (including floating representation concerns).

Knownness is not uniformly a pure tree predicate today: `is_known(Str)` reaches
`known_text`, which can read deferred array contents or reify a pointer. `static`
consults provenance, whose reference case can create tokens or reject a foreign
task capture. Recommended design: distinguish observation through the evaluator
from pure classification of already captured data (O08), rather than promise a
pure pass over the current representation.

## R07–R08: places and path knowledge

| Place shape | Payload and creation | Identity / valid use |
|---|---|---|
| `local` | Type, name/id, native owner, declaring block and lightweight frame-owner token | Tracked leaves until escaped; must not retain a complete evaluation frame |
| `temp` | Type/name/id/owner | Result of an ordered computation or snapshot |
| `lv` | Type/name/id/owner | Loop-round storage; changing loop state is not a compile-time constant |
| `rvar` | Type/name/id/owner | Joined return result storage |
| `param` | Type/name/id/owner | Addressable task-capture parameter copy |
| `field` | Parent identity, field name/type, projection identity | Includes sum payload projection; share cached projection identity |
| `deref` | Pointer expression/type/id; optional parameter origin | Reconstructed references, checked lookups, container elements, globals |
| `index` | Base/index expressions/type/id | Raw or array element; may also name an `array_owner` |

A checked place is currently a `deref` with `{ key, call or resolve, cache }`, not
another tag. Attached container/key/position information determines ownership and
borrow validity. `round_of`, `carried_view`, `stored_view`, escape marks, cached
fields and token holders are important mutable attachments (S11/S12).
The accepted rule requires direct access and aliases to a carried native local
to observe the same current contents in known and residual rounds (W02; derivation
§3). Current round copies violate this for the read-only-alias witness. Removing
that visible difference is a required semantic correction; no particular physical
storage or attachment representation is approved by the rule.

`moved` is a **path-marker identity**, with source/releases or a held marker; it
has no address. `iv` is understood by backend traversal/declaration code, but no
active evaluator constructor was found; `global` appears in a borrow check, while
`S.global_place` constructs a `deref` of `gaddr`. See legacy disposition below.

Abstract entries have three ordinary alternatives:

- Uninitialized: `{ uninit = true }`.
- Pending: `{ val, mat = false }`; native storage need not contain the value.
- Materialized: `{ mat = true, ver }`; reads must use the current version.

Moved/held path entries and range facts are separate domains even though current
state tables mix some of them. A join can produce predecessor writes/releases,
not just a new table. An escaped identity shared across arms does not make those
arms' pending contents shared.

## R09: residual expressions

This is the **current** vocabulary. Revision 2's [derivation §5](derivation.md#5-the-resulting-core-responsibilities-not-a-module-tree)
proposes explicit ordered execution sites rather than keeping calls/checks/atomics
as arbitrarily nestable expressions. The crosswalk there gives each current group
a disposition; this table does not freeze a replacement tag or family per row.

Payload columns omit the common `op` and normally present `T`. `[]` means ordered
children, `?` optional. A type, place, function, global or extern is an identity
edge, not a structural child. Intermediate sum `.as` projection and wait markers
currently lack a normal typed-value shape; this exception must not be lost.

| Tags | Payload / structural children | Identity edges / producer |
|---|---|---|
| `const`, `zero`, `null` | Scalar `v` or no payload | Native type; constructors/reification |
| `param` | Name | Function identity when available; materialization/capture |
| `read`, `addr` | No ordinary child; address computations live in the place | Place, optional read version/loop marker; reads/reification |
| `gaddr`, `fnaddr` | No child | Global/function; declaration/address taking |
| `field`, `array_index` | `a`; name or `idx` | Source type/projection meaning; member/indexing |
| `agg`, `array` | `fields` by declared name or sparse zero-based index | Type determines field/element order; reification/storage |
| `sum`, `tagname` | Alternative; optional `e` payload for `sum` | Sum type (`T` or `sum`); constructors/matching |
| `bin`, `cmp` | Operator `o`, `a`, `b` | Numeric semantics from type; smart operations |
| `un` | Operator `o`, `a` | Numeric/boolean semantics; smart operations |
| `and`, `or` | `a`, `b` | Short-circuit result; only after effect/order obligations are handled |
| `conv`, `vaconv` | `a`; ABI promotion code for `vaconv` | Destination type; coercion/foreign varargs |
| `sizeof`, `cconst` | Referenced type `sizeof`, or foreign constant name `cconst` | Header/ABI facts, not ordinary host constants |
| `call` | `args[]`; stack/result-placement metadata | Exactly one native `fn` or foreign `ext`; caller graph attachments |
| `calli` | Callee `a`, `args[]` | Function-pointer signature; no derived native ownership summary |
| `rtcall` | Runtime name `cname`, `args[]`; optional place attribution | Runtime resolution; effectful even if its type is scalar |
| `atomic` | `ptr`, `args[]`, operation/order/failure order | Optional writable `expected_place` for CAS; an address edge |
| `stack_index`, `res_index` | Local offset, or result index `j` | Result-region function for `res_index`; memory placement |
| `slot_at` | `slot` | Checked runtime slot address; may fault |
| `task`, `ops` | No ordinary child | Ambient native task/thread records; runtime primitives |
| `block_fn`, `block_env` | No ordinary child | Owning blocking wait supplies meaning; not standalone backend expressions |

Operator sub-vocabularies are finite: binary `add sub mul div mod band bor bxor
shl shr`; comparison `eq ne lt le gt ge`; unary `neg not bnot`; atomics `load store
exchange cas fetch_add fetch_sub`. Memory orders and varargs ABI codes have their
own admission rules. They are not new expression families per operator.

**Required graph rule:** enumerate structural children, address dependencies and
identity edges separately. A copy preserves identities; dependency collection
follows selected identities with a visited set; ordered evaluation does neither
by iterating arbitrary Lua fields. Calls, atomics, checks and waits cannot be
classified as freely duplicable just because their expression is small.

## R10–R12: commands, incomplete output and completion

| Command | Payload / children | Construction or phase obligation |
|---|---|---|
| `store`, `let` | Destination place, expression `e` | Mutation versus captured result; reads happen before invalidation/release |
| `expr` | `e` | Ordered effect whose value is unused |
| `setparam` | Parameter name and `e` | Root tail edge; participate in parallel assignment and pointer-origin analysis |
| `if` | Condition `c`, blocks `a`, `b` | Both blocks remain patchable until reconciliation |
| `loop` | Body, top/end labels as applicable | Loop state initialized outside; back-edge moves are simultaneous |
| `ret` | Optional result `e`, optional type | Result computed before storage teardown |
| `goto`, `label` | Label identity/spelling | Exit stores and releases precede the jump |
| `wait` | Callee/args/result/operation count/site, optional blocking body; or yield marker | Suspension belongs to task; plain thread blocks; inserted yield has its own shape |
| `spawn` | Task function identity and capture arguments | Copy before start; task's frame owns copies |
| `fence`, `trap` | Memory order or message expression `msg` | Ordered runtime behavior; diagnostic message is an expression edge too |
| `gs_reset` | Stack index `k` | Preparation-only restoration using saved top |
| `nop` | No finished semantic payload | Current hole encoding; erased once construction is complete |

`for` (iv/type/lo/hi/step/body) and `break` have backend consumers but no active
staging producer found. Numeric source loops currently use `S.loop` machinery.
They require explicit disposition, not automatic adoption as new core kinds.

R11 comprises lazy-read registrations (`place`, nodes, version, hole, done),
return sites (block, end-state, jump), deferred inferred payloads, immediate-match
groups (alternative, sites, landing label/base), and loop exits. These are not
executable commands. **Recommended:** explicit construction obligations owned by
the evaluation, with finished bodies handed to preparation (D02). A completed arm
can still owe predecessor/snapshot completion to its enclosing construction.
Revision 3 prefers bindings plus attempt-owned snapshot requirements, resolved by
the construction owner; undo requires a reason to edit surviving work immediately
(derivation §6). The loop candidate (§3) additionally distinguishes supplied entry
values from reusable header assumptions, invocation input bindings from earlier
read bindings, and continuing sites from exit sites. These are construction
contracts, not new prepared expression tags or a general dependency-repair graph.
Invocation return does not necessarily close every construction binding: parent
acceptance transfers eligible output and its outstanding obligations, but cannot
extend a native lifetime or legalize a stale raw read. Publication must resolve
construction operands and reject references to discarded storage (derivation §6).
Do not freeze `nop` as the universal unfinished representation.

R12's current protocol uses ordinary returns plus private Lua-error signals:

| Outcome | Payload / destination | Completion responsibility |
|---|---|---|
| Direct result / collected exits | Value/place/host result or Unit; owning invocation | Reconcile state, views and payload, release frame lifetime |
| Known tail round (`tail`) | New arguments and exact target frame | End round tokens; continue in place |
| Construction restart (`restart`) | Target frame, mode, optional widening/escape/adoption | Current driver discards output and replays; cause is not always failed header knowledge |
| `rebuild_moves` | Target function; known move facts live in module registry | Unwind to its builder; rebuild its dependency attempt |
| `rebuild_results` | Target function; result/arena placements | Same, with explicit placement feedback and convergence bound |
| User rejection / host failure | Located diagnostic or original failure | Restore dynamic bindings; do not treat as a successful retry |

Frame rollback also occurs **without** a signal: after same-key recursion discovers
a shared function, `run_frame` can discard a completed inline expansion and emit a
call. Derivation §3 separates this boundary choice from invalidated knowledge and
from the several causes sharing `restart`.

`Matched` is a private carrier naming the producer frame awaiting handler
completion. It is neither a native sum nor a general result escaping that activity.
D03 now proposes preserving the existing targeted transport provisionally for M1,
not the withdrawn new private-unwind protocol or a coroutine driver (derivation
§§8/9). The scoped freeze was withdrawn after the user's memory-model/scope objection. Explicit control outcomes,
construction feedback and deep invalidation remain distinct; only the matching
live owner consumes a targeted transfer, with completion and host-edge checks.

## R13–R17: lifetimes and program graphs

**R13 borrow tokens.** Current conceptual kinds: activity, owner, parameter.
Activity tokens currently have no explicit `kind`; others name owning function,
parameter index or place, frame/block lifetime and diagnostic name. Contents,
element and shared-position tokens depend on whole/parent tokens and carry
key/position information. A union is `{ tokens = set }`; ending changes the token
and may detach it from a holder with undo logged. Distinct known keys can preserve
unaffected borrows. Never turn all pointer-like native values into scoped borrows.

**R14 holdings.** A slot names its holder place/block, release fields, serial,
release operation and aliases, and one storage class: local stack `k`, result
stack `res`, or adopted/header storage. Reservations and allocation ordinals may
accompany it. Tenant records name holder storage, offset, ordinal and quiet-window
time. Moving gives the destination a new slot over the same storage; it does not
transfer a mutable slot record between places. Placement plans and arena-event
history are evidence, not residual allocations or native handles.

**R15 function phases.** Core identity/signature/body (`name`, `cname`, `word`,
`key`, parameters, result, locals, body) is accompanied today by:

- Construction: `status`, `dynamic_pos`, parameter origins/names, capture,
  tail-entry label and result/arena placement attempts.
- Call effects: borrowed-result origins, parameter borrows, shrink/restructure/
  abandon/move facts, recursive assumptions, owner/growth sites and root exits.
- Graph/storage: callees, call nodes, stack counts, result regions/offsets,
  stack-base requirements and task/wait flags.
- Later consumers: cleanup/prepared/emitted flags, C/linkage names, declarations,
  task frame/step plans and profile attribution.

These are separate phase-owned responsibilities, not an argument for one giant
closed struct with all fields optional. Building function identities can be
referenced recursively, but only the explicit incomplete-summary policy may
interpret them. Native boundary isolation must reject foreign locals unless an
explicit task-copy capture protocol handles them.

The construction probe in derivation §6 demonstrates why definition lifetime is
not call-occurrence lifetime. Proposed: each call belongs to its caller's output;
reverse indexes derive from live owned sites or remove discarded entries. A
complete callee may survive caller rejection without retaining that caller's
operands. A body still depending on unfinished recursive construction is not an
independently reusable definition merely because its own callback returned.

**R16 module.** Lists/maps for definitions, exports, externs, names, specialization
keys and counters; runtime lazy declarations/resolver; global owner setup;
recursive move feedback; prepared reachable view and layouts. An export view can
inherit definitions but must not inherit proof that a different ABI root set is
safe. Cache validity belongs here, not to source types or a backend's name map.

**R17 task descriptions.** Capture records name parent evaluation, scope,
place/leaf maps, ordered copied values and owned rebased array roots. Select cases
are `recv`, `send`, `take`, `after` descriptors with typed handlers and operation
inputs. A wait result is a typed value/result place; pending/completed/cancelled
runtime states are Nua runtime policy, not specializer retry outcomes. A blocking
body has access to the suspended task frame, not independent sendable captures.

## R18: backend-local domains and retained edges

C emission produces ordered declaration/type/global/function/text sections, with
per-function place names, declarations, labels, precedence and task resume points.
`jitgen` produces the same program through `cjit` types/values/CFGs. C descriptors
(`int`, `float`, `bool`, `void`, `ptr`, `array`, `fn`, `struct`, `union`) are not R03:
they describe the target C ABI, including promotion/layout rules.

The C-subset reader has tokens, declarations, expression AST (literals, names,
unary/binary/cast/call/member/index/assignment/conditional/initializer/sizeof and
increment forms), statement AST (block/declaration/expression/conditional/loops/
return/break/continue/empty), scopes/macros and lowered CFG. It reads the permitted
C boundary, not emitted Nua C. Preserve its independent admission errors; no
fallback to another compiler is implied. It needs its own field-level inventory
if a later milestone rewrites it.

Header probe requests/results, external tool options/artifacts, gccjit contexts,
compiled result handles, FFI thunks and direct-backend stencil/relocation artifacts
are explicit outside resources. They have release/cache/ABI contracts, not Nua
knownness or path state. See O38–O41 and S25–S27.

## Legacy and phase-only disposition register

| Observed spelling | Evidence | Recommended disposition before sealing replacement families |
|---|---|---|
| Value `pack` | `shareable` tests this tag; actual packs use `Pack`, not `V` | Do not add a phantom native value; retain pack input protocol R05 |
| Place `global` | Borrow-store check; globals produced as deref/gaddr | Model global origin explicitly, not an unproduced place variant |
| Place `iv`; commands `for`, `break` | Backend consumers; `plan_jumps` makes a local `for` marker | Exclude from new evaluator output unless a concrete producer is chosen; adapt retained consumers explicitly |
| Expression `rt` | Old equality/cleanup tests; producer emits `rtcall` | Do not preserve as an alias; audit effect classifications (G02) |
| Expression `place` | Synthesized by `walk_block` for destinations | Traversal event/address dependency, not backend expression |
| `block_fn`, `block_env` | Blocking wait arguments | Restrict to that enclosing construction, not universally valid expressions |
| `nop` | Multiple deferred obligations | Resolve/erase at completion; do not lose the underlying obligations |

A lexical scan located these cases; producer/consumer reading classified them.
“No producer found” is not a proof no external embedding can ever construct a
plain table. No new compatibility path for arbitrary internal tables is proposed.
