# Operation inventory

Part of the [review candidate](README.md). The units here are responsibilities,
not one row per Lua helper or a proposed module per row. `stage` means
`nua/stage.lua`; other short source names mean `nua/<name>.lua`. Representation
IDs are in [representations](representations.md), state/boundary IDs in
[state and boundaries](state-and-boundaries.md).

**Required:** decide an operation's primary result, effects and order before
writing handlers. No handler may return an expression where its siblings return
a value, or silently mutate outer output where its driver promised a new result.
Expected control outcomes and rejection are part of that contract.

The [derivation](derivation.md) uses these rows as a coverage challenge,
not forty-five mandatory abstractions. Its ordered-execution proposal changes
where effects are represented, not whether dependency/movement policies are
needed. General known-result memoization is proposed for omission; definition
sharing and valid lookup reuse remain separate capabilities.

## Application: supply and dispatch, not a native call by default

| ID / operation | Primary result | Effects, ordering and rejection | Current anchors |
|---|---|---|---|
| O01 Enter/leave compilation | Translation/staged module/prepared output according to requested entry | Install module cache/prelude/configuration; restore host bindings on failure too; reject nested compilation | `nua.compile`, `loader.with_context`; B01 |
| O02 Translate source and prove applications | Mua AST facts and staged Lua text | Own output/scopes; preserve lexical shadowing, openings, source lines and grouping; reject invalid typed forms | `front.host`, `G:expr`, `G:stat`, `application.analyze` |
| O03 Bind compiler/library vocabulary | Program prelude and compilation-local library bindings | Decorate host-lifetime types without retaining old compilation words; algorithms remain Nua | `nua.prelude`, `Mem.prelude`, `decorate`, `Str.prelude`; B02 |
| O04 Supply requirements | Partial word or saturated argument supply | Coerce in supplied order; static-only incomplete supply; no body execution before saturation; reject illegal packs/nil rest components | `S.word`, `h.apply_word`, `static_arg`, `coerce`; B03 |
| O05 Dispatch application groups | Application result, including overapplication result | Collect word supply; preserve genuinely curried host calls; method/opened/receiver lookup retains binding rules | `S.chain`, `mchain`, `ochain`, `h.call_word`, `h.call_callback` |
| O06 Evaluate saturated application | Value/place/host result or Unit; owned construction feedback | Execute in caller by default; choose compile-time entry, explicit boundary or necessary materialization; limit nonterminating specialization, not silently fall back | `invoke`, `comptime`, `Builder:apply`, `run_frame`; B04/B07/B10 |

Specialization key construction is part of O06/O24's sharing contract, not a
universal expression hash. It combines word identity, typed known arguments,
static host inputs and dynamic argument shape (including shared-owner-position
information). Known-key equality and type identity must not be replaced by display
name equality. Measurement-only `call_policy` belongs to O43, not normal dispatch.

## Evaluation and residualization: interleaved work

| ID / operation | Primary result | Effects, ordering and rejection | Current anchors |
|---|---|---|---|
| O07 Construct/check native types | R03 type identity | Intern admitted parameterized types; complete nominal declarations; reject incomplete by-value recursion, invalid payloads/ABI types | `types.ref/struct/sum/owner/fn/array/atomic/chan/pool`, admission predicates |
| O08 Observe knownness, provenance and identity | Predicate, captured known content, equality or specialization component (separate operations) | Do not conflate content-known with static/capturable. Current text/provenance queries can read/reify/create tokens; equality must preserve native scalar meaning | `is_known`, `static`, `same_value`, `h.value_view`, `Str.known_text`, `arg_key` |
| O09 Perform native scalar computation/conversion | Typed known result or residual value | Use target width, signedness, float rounding and UB rules; foreign promotions explicit; hooks may evaluate; reject invalid mixed operands | `binary/unary/compare`, `value_of/coerce`, `fold.*`, `ub_guard` |
| O10 Build/project aggregate contents | R06 record/array/known-alternative value or projected input | Preserve field/index order where work can emit; persistent sparse array updates; contextual expected type required | `Type.__call`, `constructor`, `array_value`, `array_value.lua`, `raw_member`, `zero_value` |
| O11 Read a place | Staged contents or residual read | Check lifetime/ownership/version; capture foreign task data; resolve checked storage; flush pending state when needed; reject uninitialized/moved reads | `Builder:read`, `tracked`, `reref`, `flush_pending`; B05/B11 |
| O12 Assign/bind a source location | Updated contents/path state | Snapshot outstanding reads before overwrite; field-wise stores, ownership transfer, view checks and loop adoption; reject incompatible assignment | `Builder:store`, `S.decl/set/assign_*`, `loop_write`, `h.check_store_view` |
| O13 Preserve an evaluated value | Bound value plus owned snapshot obligations | Capture untracked reads now; register tracked reads for lazy snapshot at original binding point; expire with invocation | `Builder:bind`, `snapshot_read`, `invalidate`, `expire`; B04/B07 |
| O14 Reify contents/address | R09 expression | Validate borrows; may materialize/escape/resolve/restart; cannot reify a fresh owner as a scalar; preserve pending-store path | `ex`, `whole_place`, `materialize`, `escape`; B05/B07 |
| O15 Append residual work | Command/execution occurrence owned by current construction | Reject runtime effects without native destination; suppress dead-path emission; validate reads; own structure, name identities explicitly; call-site indexes follow occurrence lifetime | `Builder:emit`, `copy_expr`, `check_reads`; B04 |
| O16 Evaluate/reconcile alternatives | Branch blocks, end states/reachability, joined continuation | Known condition executes one arm; dynamic arms fork facts, share identities; predecessor stores/releases before continuation | `S.if_`, `short`, `Builder:sub/join`, `release_moved_on`; B05 |
| O17 Evaluate rounds and edges | Completed round/loop or owned construction feedback | Keep accepted known rounds; direct access and aliases share a native local's current contents in known/residual rounds (accepted W02 rule); header facts admit initial and continuing inputs; establish exits separately; simultaneous edge moves; refuse changing borrow origin | `S.loop/for_/while_`, `run_loop_body`, `jump_next`, `parallel_assign`, `loop_exit`; B07/B08 |
| O18 Construct/move/copy owners | Destination holder / constructed owner | Ordinary owner assignment transfers; explicit copy uses Nua library algorithm; sum/aggregate ownership recursively honored | `init_resizable`, `init_on`, `init_sum`, `move_owner`, `Mem.copy`, `put_owner` |
| O19 Establish/check/end borrowing | Provenance, valid use or rejection | Whole/contents/activity/element/position lifetimes; logged ending undo; stored views cannot outlive owner; boundary summaries separate | `h.*token`, `place_view`, `end_token`, `S.view_of/fixed`; B06/B07/B09 |
| O20 Hold/release residual storage | Holdings/claims and ordered release commands | Slot records stay with holder; moved paths do not release twice; reverse lifetime release before exits; block owns normal cleanup | `gs_alloc/register_slot`, `hand_off/release_slots/gs_close`, `release_since`; B05–B10 |
| O21 Discover result/arena placement | Placement feedback and result-region obligations | Record allocation identity/span and quiet-window events; reconcile recursive destinations; rebuild when feedback changes | `h.place_result/result_destination`, `result_region`, `pend_arena/open_tenant`; B09/B10 |
| O22 Resolve checked/library places | Place valid at this path/epoch | Fix semantic index at use, stage lookup once, invalidate on mutation/call/wait/retry; fixed iteration guards structural changes | `checked_place/resolve_checked`, `Mem.fix_index`, `S.note_structure/retire/restructure` |
| O23 Complete returns and immediate matches | Joined result and end state | Own return sites; capture payload before mutations; patch before jumps; infer callback results/exhaustive handlers; reject escaping frame borrows | `return_value/finish_frame/matched_return`, `match`, `h.land_match/finish_match`; B06 |

O12/O13 distinguish **a place's current contents** from **a value taken earlier**.
O14 is not a pure lowering pass. O18/O20 are compile-time bookkeeping that
produces residual ownership operations, not a hidden host implementation of
container algorithms. Derivation §9 distinguishes a pure agreement decision over
captured scalar contents from O16's effectful predecessor establishment. This is
an internal result/effect contract, not two new compiler passes. Deferred-read
requirements in O13/O15 belong to construction; owner completion resolves them.
O17 must distinguish loop shape, participating state, header agreement and exit
agreement (derivation §3). An observed restart is not proof that previous
specialization was invalid; construction feedback is not one universal outcome type.
The candidate re-evaluates a body when its header assumptions weaken; it does not
restart on participation discovery alone. Loop-input bindings preserve nameable
operands but do not by themselves validate lookup reuse or repeated lifetimes.
Derivation §6 makes the handoffs explicit: body return, parent adoption, discard,
publication. Returned compiler records do not extend native lifetimes; a retained
callee does not own discarded callers' execution sites or operands.

## Materialization and foreign/task boundaries

| ID / operation | Primary result | Effects, ordering and rejection | Current anchors |
|---|---|---|---|
| O24 Materialize/share/rebuild a specialization | R15 function identity/body/summaries | Register before recursive body entry; retain known inputs, parameterize the remainder; separate attempt output from cross-attempt feedback; reject foreign locals | `call_materialized`, `h.build_with_moves`, `build_function`, `export_word/native_word/resolve_runtime`; B09/B10 |
| O25 Invoke a materialized native function | Call result (including owner destination/borrow origin) | Materialize arguments, transfer owners, invalidate lookups, reserve result storage, apply summary effects; unfinished summaries use explicit conservative/rebuild policy | `Builder:emit_call`, `h.argument_view/result_destination`; B09 |
| O26 Cross raw/foreign ABI or expose entry | Native address/result or extern/global/entry descriptor | Exports/function pointers constrain ABI and layouts; no inferred ownership summary for foreign/indirect calls; reject unsupported scoped values/owner transfers | `S.extern`, `X:__call`, `call_fn`, `fnptr`, `global`, `call_arg`; B09/B14 |
| O27 Construct task/captures | Resumable function and ordered spawn arguments | Bake known captures, copy dynamic sendable values, rebase views onto task copies; reject parent references and incompatible slots | `spawn_block/spawn`, `capture_read/place/leaves/leaf`, `check_isolated`; B11 |
| O28 Enter task scope, block or wait | Scope/body result or typed wait result | Scope retires after body; task suspension differs from plain blocking; blocking body borrows frame; reject waits hidden behind unsuspendable native boundary | `S.tasks/blocking`, `wait_op`, `check_task_waits`; B12 |
| O29 Stage channels/pools/select/I/O | Typed result or matched-handler result | Preserve tentative send/slot ownership, commit/discard rules and deadlines; first-of selection differs from uncancellable kernel work | `chan_method`, `first_of`, `pool_method/index`, `io_wait/io_vocabulary` |
| O30 Supply type/library/platform primitives | Operation-specific staged result | Raw pointer/slice/index/bounds, atomics, globals, text/host conversion and library hooks; not one opaque compiler algorithm per feature | `member_ptr/slice`, `S.Array`, `bound_check`, `atomic_method`, `strings`, `run_hook`, `S.owner_type` |

O30 is an extension-boundary inventory, not a proposed megafunction. Its finite
native outputs are covered by R03/R06–R10. Open library methods stay open and run
through these operations. Any touched expressible algorithm belongs in Nua;
compiler primitives must describe the missing general capability, not a library
feature's policy. The current known-float/text host edges need review on their
own merits when touched, not automatic translation into more opaque helpers.

## Preparation and lowering

| ID / operation | Primary result | Effects, ordering and rejection | Current anchors |
|---|---|---|---|
| O31 Find reachable program | Ordered functions and dependency set | May resolve lazy Nua runtime words; include generated runtime roots, address-taken functions, tasks and waits | `G.reachable`, `nua.attach_runtime`; B13 |
| O32 Check task/global effects | Valid program or diagnostic | Monotone origin/contents analysis, plain/task contexts separate, global cells shared; **before cleanup**; opaque calls conservative | `task_globals.check`; S22 |
| O33 Clean completed residual code | Semantics-preserving body | Current ordered in-place rewrites; no assumption of a structural fixed point; preserve effects/provenance needed by earlier checks | `G.cleanup` and local rewrites; S23 |
| O34 Determine storage layouts | Exact view's type → storage-field mapping | Address/ABI/opaque observations pin representation; never mutate declared source fields | `layout.analyze/fields`; S24 |
| O35 Plan stack/call/result regions | Function/call storage obligations | Graph fixed points and cycle checks; preserve held-owner growth restrictions and caller-provided result destinations | `G.plan_stacks`, `S.result_region`; S24 |
| O36 Complete runtime exit/suspension work | Prepared bodies | Evaluate return values before reset; restore stacks at exits; add task yield points without duplicate insertion | `stack_exits`, `insert_yields`; B13 |
| O37 Publish prepared view | R16 prepared reachable program | Enforce phase order, exact-root/cache validity and shared backend contract; no hidden alternate preparation in C/JIT | `G.prepare`; B13 |
| O38 Lower prepared program | C sections/text or gccjit unit/CFG | Backend-local naming/types/declarations/jumps/task frame; obey same arithmetic/storage contract; reject unsupported input | `G.emit/emit_split/header`, `JG.build`, `cjit` core |
| O39 Obtain foreign facts | Header constants/layouts/getters | Probe or valid cache/embedded platform facts; external tool failure is an error, not fabricated facts | `probe.requests/run/layout/constant/read_variable`; B14 |
| O40 Build/load artifacts | Object, library or native result | Explicit compiler/runtime/platform capability; owned files under ignored paths; no silent backend substitution | `toolchain`, `runtime_build`, `C.context`, `Native.runtime`; B14 |
| O41 Expose/release native callable | Callable wrapper plus owned live result | Preserve FFI types, trapping ABI and result/code lifetime; export view needs its own preparation | `Native.compile/word`, `C.code/release_result`, `Ctx:release`; B14 |

Current O33 order: drop no-ops; prune terminals; propagate returns; prune again;
drop next-label jumps; remove unused labels; remove dead stores; hoist common
work; flatten conditionals; inline temporaries; repeat jump/label cleanup; remove
final void return. This is cleanup **after** in-place specialization, not the
inlining engine. Each rewrite's preservation/effect policy must be re-established
against the closed command/expression vocabulary (G02), not copied from a generic
identity visitor that accidentally loses an address edge.

## Inspection and verification operations

| ID | Primary result | Contract / disposition |
|---|---|---|
| O42 Inspect and compare representations | Stable diagnostic form; purpose-specific equality/difference | **Required for the rewrite:** print each closed domain first; label identity edges; distinguish opaque host inputs. Do not use one deep equality for values, alias identities, keys, analysis convergence and output comparison |
| O43 Diagnose and attribute | Located failure, trace or profile report | Preserve innermost useful source and invocation trail; profiling may observe but not corrupt completion/rollback. `size`'s inline/share policies are explicit measurements, not fallback compilation |
| O44 Validate representation/pass completeness | Accepted phase/kind coverage or immediate construction error | **Required for the rewrite:** load all passes with contracts on; reject missing/extra/non-function handlers, invalid list elements, invalid phase and foreign identities; name deliberate non-contributions |
| O45 Check semantic/state obligations | Pass/fail/unsupported evidence, with reproducible input | **M1 proposal:** source-to-prepared-output/C-text, expected scalar transitions, publication refusals and lifecycle/graph checks. Native/backend checks need a separately agreed budget; emitted text is not native acceptance |

Existing inspection is fragmented (`__tostring`, size/profile, emitted Lua/C and
specialized test traversals). No complete family printer/validator or universal
reference interpreter is claimed to exist today.

## Candidate pass coverage and explicit defaults

“Pass” means dispatch over a closed data domain, not every row above. Activities
like applying a word or retrying an invocation own control and completion; they
can invoke passes without themselves becoming passes.

| Domain | Candidate operation | Handler/default contract |
|---|---|---|
| R03 native types | Borrow/sendability/admission queries, ABI lowering, type dependencies | Each current kind admitted/rejected/recurred explicitly; open library declaration interpreted through its defined interface |
| R06 staged values | Printing, data equality, binding-time classification of captured data | Every variant named; no body execution. Effectful observation remains a separate evaluator operation |
| R06 staged values | Reification/binding/widening | Same primary result across handlers; explicit construction rejection for `fresh`; view checks and storage effects declared; immutable cases can use named identity handlers |
| R07 places | Root/projection/address calculation, dependency edges, printing | Identity preserved; field/index/deref edges explicit; moved markers excluded from address domain |
| R09 expressions | Copy, print, size, storage freedom, effect classification, selected dependencies | Constants are explicit leaves; calls/atomics/checks are never generic “pure” leaves; copy shares types/places/functions rather than recursing through them |
| R10 commands | Print, destination/read/effect collection, cleanup, backend lowering | Ordered child blocks; explicit no-contribution cases; rewriting driver owns output, not a field planted on caller state |
| R12 outcomes | Completion dispatch | Every destination/outcome handled or forwarded to its actual owner; diagnostic never mistaken for retry |
| R13/R14 provenance/holdings | Inspect, validate, transfer/release planning | Token/slot identity and path ownership explicit; no generic deep copy of live lifetime state |

### Minimum residual-effect policy for review

These preservation obligations apply to the current expression inventory. The
revision 2 proposal moves execution-sensitive operations to ordered sites rather
than preserve their arbitrary nesting in expression trees; see derivation §5 for
the R09 crosswalk. More precise elimination still needs a proof appropriate to
the operation; “storage-free”, “effect-free” and “safe to duplicate” are not synonyms.

| Expression group | Required consideration |
|---|---|
| Constants/zero/null, numeric operators, conversions, aggregates/sums/projections | Combine child obligations; preserve numeric/UB rules and conditional evaluation; destination type alone proves no purity |
| Parameters | No read of mutable native storage, but root-tail `setparam` changes the parameter across edges; facts cannot pass that boundary unchecked |
| Reads | Depend on place/version and hidden address computations; do not move a read across mutation, lifetime end or a check it depends on |
| Addresses/global/function addresses | Preserve identity and address-computation dependencies; compile-time escape/reification effects have already occurred, but cannot be ignored while producing the expression |
| Native/foreign/indirect/runtime calls | Retain ordered effects unless a specific proven summary permits removal/movement; `ext.variable` denotes a foreign read, not an arbitrary pure constant |
| Atomics/fences | Preserve ordering and memory effects, including CAS's non-atomic expected destination |
| Checked slot access | Preserve its check/fault behavior even if the value is unused |
| Task/operation-record access | Ambient execution dependency; not a static host value or freely movable across suspension |
| Stack/result indices and foreign sizeof/constants | Depend on prepared storage/ABI facts; cannot fold from an unrelated module/platform's metadata |
| Blocking placeholders | Only meaningful in their owning wait; reject as standalone general expressions |

For repeated behaviors, write a named vocabulary that **lists all its kinds**:
identity, leaf/no-child, no-contribution, rejecting, or common recursion. Spread
that vocabulary into the operation and override deliberately. A newly added kind
must force a coverage decision even if the eventual decision is “unchanged”.

## Traversal and order contracts to freeze

1. **Evaluation order:** supplied arguments, staged instructions, simultaneous
   assignment capture and child work that emits commands are ordered explicitly.
   Host/Mua expression semantics remain authoritative; do not invent a stronger
   source evaluation order by mechanically copying a pass example.
2. **Record order:** declared fields when evaluation/reification can emit; sparse
   array indices in a documented deterministic order. Unordered mathematical sets
   can use arbitrary iteration only where no observable order is introduced.
3. **Structural walk:** visit only documented expression/command children.
4. **Address walk:** additionally expose pointer/index computations inside places,
   CAS expected destinations, wait results and other address-bearing positions.
5. **Dependency walk:** follow selected function/type/global edges with visited
   sets; include indirect targets/opaque conservatism where required by analysis.
6. **Copy/rewrite:** preserve identity edges, own the newly produced structure,
   and do not mutate an enclosing rewrite's output during nested work.
7. **Observational equality:** state which notion is being tested. Floating bit
   identity, specialization equivalence and mathematical equality are not the same.
8. **Failure order:** completion runs at its owning boundary; no unchecked handler
   or unsupported backend silently falls back to a different meaning.

These are replacement requirements, not a claim that every current ad-hoc walk
already satisfies them. In particular old `rt` versus `rtcall` checks and walker
synthetic nodes need explicit reconciliation before closing the operation matrix.
