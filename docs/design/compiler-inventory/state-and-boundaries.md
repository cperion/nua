# State ownership and boundary inventory

Part of the [review candidate](README.md). Roles from the guide: **I** inherited,
**A** accumulated, **E** evolving, **P** produced, **C** capability. Roles belong
to an operation: produced code becomes input to a later analysis. These are design
questions, not fields of a proposed universal context framework.

Current field names below are source crosswalks. The replacement should name the
responsibility, not preserve `Builder` merely by spreading it into more files.
The revised [derivation §6](derivation.md#6-where-private-construction-helps-and-where-it-does-not)
prefers owned snapshot requirements resolved on completion, before introducing
undo for surviving edits. It now distinguishes body return, parent adoption,
discard and publication, including caller-owned call occurrences. The rows below
remain an audit of obligations, not a mandate for 27 state objects or a guarantee
that all changes can be deferred.

## State register

| ID / state | Creator and current storage | Role and validity boundary | Completion / result owner |
|---|---|---|---|
| S01 Host module environment | `loader.with_context`: loaded registry/table, searchers, preload, paths, active guard | I/C; per compilation. Seed with existing host modules, isolate newly loaded modules; not a sandbox | Loader restores prior bindings on success/error; program module values belong to compilation |
| S02 Type/library identities | `types` caches; `memory` families, derived layouts, module-specific APIs/decorations; `strings` library lookup | C/I; native type identity may survive resets, Nua word bindings may not | Compiler host owns identities; exact module owns derived representation. Existing post-scope `layouts_module` fallback is observed, not a new compatibility recommendation |
| S03 Compilation definitions and fresh supplies | `S.reset`: functions, key/export maps, externs/names, globals, lazy runtime definitions/resolver; module uid/version; host word/task/slot IDs and memory clock | A/P/C; module replaced on compilation, identities/counters not frame-rollback output | Compilation owns definitions; graph lookup can share finished independent functions; fresh identifiers are capabilities, not path facts |
| S04 Translation work | `front` generator/body: output/line/file, scopes, parent, region, loops, lexical/application facts | I/E/P; entering body/scope saves or extends bindings, fresh nested output as appropriate | Translation owns text/facts; restore outer body/output; Mua owns AST vocabulary |
| S05 Word and supply | `S.word`, partial/method/boundary wrappers: identity, body, params/result, supply/options | I/P; supply becomes immutable input to invocation; no native body before saturation | Partial word owns supply, shares body/identity. Invocation options must not leak to next application |
| S06 Active evaluation | `new_builder`: fn-or-none, block, state, dead, depth, active stacks, memo | E/P; in-place application shares caller evaluation; materialization creates a new one | Owning evaluation produces result/residual work; lack of native destination rejects residual effects |
| S07 Invocation/region stack | `push_frame`, `run_inline/run_loop`: frames, regions, active-key counts, depth, recursion marks | I/E; push/pop around body; dynamic region changes generalization policy | Invocation owns returns/lazy registrations; unwind also on signal/error; stable lightweight lifetime owner is not the frame |
| S08 Path knowledge | Declare/store/sub/add_facts: place-state, dead, range facts, path identity, moved/held entries | E; fresh arm maps and path; join reconciles; loops generalize; rollback restores selected state | Branch result includes end-state and reachability; parent owns joined continuation, not individual arm's facts |
| S09 Residual construction | `emit`, new locals/temps, direct block insertions: block lists, fn.locals, expressions, emissions/escapes logs | P/E; mutable until all owning completion obligations settled; frame retry truncates only its suffix | Construction owns code; emitted expression children copied; place/type/function identities shared |
| S10 Deferred snapshots/exits | `bind`, returns/matching: lazy per-place and per-frame registrations, holes, copied nodes, return/landing sites | P/E; current writes may patch earlier sites; semantic expiration is distinct from compiler-record lifetime | Construction owns bindings/requirements; acceptance transfers their obligations with output, never native loan validity; publication resolves them (derivation §6) |
| S11 Place attachments | Place creation/projection/reconstruction: owner/block/frame token, fields/index projection, round origin, escape, checked descriptor, container/key/position, carried/stored views | I/E; shared identity across paths, but contents are path-local; escapes have undo log | Place identity owned by its storage construction; projection caches must not turn discarded computations into live storage |
| S12 Borrow/iteration lifetime | Token creation, `frame_tokens`, `capture_tokens`, token sets, stored views, `shrink_log`; fixed-iteration marks/keys | E/A; ends at owner/activity/frame or invalidating operation; recorded endings undone on retry | Lender owns lifetime; holder owns token reference; no native ABI addition. `S.fixed` unwinds iteration count around its body |
| S13 Storage holdings | `register_slot/claim`: gs_live, gs_claims, gs_owned by block, gs_extra, gs_res_slots, registered slots | E/P; moves/replacements/path joins change who holds; snapshot restores selected collections | Declaring block/holder owes releases; transfers create destination slots, not shared mutable holder records |
| S14 Allocation and arena history | `next_allocation`, `gs_alloc`, `arena_event_key`: alloc_count, alloc_spans, arena_events, host clock, tenant windows | A/E/C; current frame rollback retains these; whole-function rebuild gets a fresh builder and placement input | Function-build activity owns evidence; ordinal association and retained-event conservatism must be explicit (G01), not hidden in shallow copies |
| S15 Callee effect summaries | Evaluation updates fn.result_params, param_borrows, shrinks, restructures, abandons, moves_out, assumed_no_move, ref-owner parameters | A/E; unfinished recursive body has explicit assumptions; move feedback can force rebuild | Function owns derived summary; caller applies it. Summaries are not caller path contents |
| S16 Call/result graph evidence | emit_call/result placement: callees, call_nodes/caller, owner_sites, grow_sites, root_exits, result_calls, has_res/result_stacks, result/arena allocation plans | A/E/P; affects recursion, destinations and later preparation; probe confirms retained metadata can name a removed caller temporary | Caller construction owns call occurrences; indexes remove/derive discarded entries. Definition validity and owner-placement feedback have separate domains (G01) |
| S17 Reconsideration work and feedback | run_frame snapshot plus widen/escape/adoption; build_with_moves options and module.moves_known | P/E; frame and function-build attempts have different domains; current restart can mean shape change, discovery or changed assumptions | Owner completes or revisits unfinished work; only justified feedback crosses attempts; do not mandate one undo/replay mechanism for all causes |
| S18 Lookup reuse | ccache, cepoch, fixed_indices; entries contain path/epoch and root/value | E; valid on same compatible path/epoch; call/loop/wait/rollback can invalidate | Evaluation owns cache; epoch advancement invalidates rather than reviving speculative lookup results |
| S19 Task capture/construction | cap.parent/scope, places/leaves/values/names/owned_roots; task flags; in_blocking | I/A/P/E; new task owns copies; nested blocking body shares suspended frame, not capture protocol | Spawn owns capture list until copied; task function owns rebased roots; restore outer block on failure |
| S20 Diagnostics and measurement | source path, active trail, emitted_stream, per-builder indices, size_profile, attribution/call_skipped | A/P; discarded command positions cleared without renumbering independent functions | Diagnostic/profile activity owns reports; must not retain abandoned statement graphs; size call policies are opt-in measurement |
| S21 Dynamic compiler bindings/configuration | current/builders, S.module, reset hooks, call_policy, user_source/path; compiler options/runtime mode | I/C/E; explicit entry/materialization/preparation temporarily bind state | Composition root owns restoration. Single active compilation is current contract; no incidental reentrancy promised |
| S22 Task-global analysis | `task_globals.check`: contexts/instances, globals/external cells, function targets, pointer cache, unknown cell, violations, changed | I/A/E/P; one reachable graph, monotonically growing origins/contents; separate task/plain call contexts | Analysis owns facts/diagnostic; no staging rollback involvement; run before evidence-removing cleanup |
| S23 Cleanup work | Per rewrite liveness/use/label maps, terminal state, substitutions; fn.cleaned | I/A/E/P; current code mutates body; proposed rewrite owns a fresh output list | Rewrite driver owns nested output; completion publishes body and invalidates dependent analyses |
| S24 Whole-program storage/stack proof | `layout.analyze`, `plan_stacks`, result_region: seen/fixed/used/layout maps, calls/need/resizes/holding/fed, offsets | I/A/E/P; exact reachable/export view; graph fixed points distinct from cleanup | Preparation owns proof and derived annotations; source type fields unchanged |
| S25 Backend construction | C Fn maps/output; jitgen unit/function/type maps; cjit context handles, types/fields/functions/globals/keep/string maps, CFG blocks/scopes | I/E/P/C; new unit/function/CFG boundary, not a staging frame | Backend owns output/context; label/declaration/task-resume state scoped correctly; gccjit context released explicitly |
| S26 Foreign facts and build caches | probe requests/cache/platform identity, runtime_build cache, Native runtime handle, toolchain/environment | I/C/P; validity depends on source/platform/options, not a word key or export count | Edge adapter owns files/subprocess resources and errors; preserve raw failure, no invented fallback/skip |
| S27 Native execution results | Compiled result, exported code pointers, FFI types/thunks/keepalives; direct backend memory if selected | P/C; result can outlive compilation/context; cannot free while callable remains live | Native wrapper/result owner controls release; platform/runtime shared state has its own host lifetime |

### Field-accounting notes

The core `Builder` construction and its later additions fall under S06–S19:
`fn block state dead frames regions active escapes emissions lazy recursive memo
depth path facts ccache cepoch initializing storeback frame_tokens capture_tokens
shrink_log gs_live gs_claims gs_owned gs_extra gs_res_slots registered alloc_count
alloc_spans arena_events result_calls fixed_indices in_blocking`.

`initializing` and `storeback` are temporary guards for initialization/loop
write-back, not inherited user facts. Method-valued fields found by a lexical
scan (such as `run_inline`, `all_slots`) are operations, not missing state slots.
`module.memo` is initialized but current application memoization uses the builder's
`memo`; do not invent a second required result-cache lifetime from an unused field.

Frames additionally carry arguments/key/shape/descriptor/mode, source/inference,
base/iteration state and block, snapshot, return sites/direct result/rvar/label,
match groups/sections, loop variables/partial masks/owned leaves/exit states,
widen/escape lists and lifetime/slot marks. These are S07/S10/S17 responsibilities,
not one timeless “function context”. Root and compile-time frames do not have all
the same fields as retrying inline frames.

## Boundary contracts

These are required postconditions grounded in current semantics. Implementation
mechanisms explicitly marked “current” may change after review. “Share” means
identity sharing, not permission to mutate every referenced object.

### B01 Enter/leave compilation

- **Keep:** existing host modules/type identities and outside native results.
- **Create/reset:** program module cache, program environment, residual module and
  command stream; per-compilation derived library words.
- **Complete:** return the requested stage's result; restore loader/cache/path
  bindings on either success or failure.
- **Reject:** nested compilation. Host-global mutations are not rolled back; no
  sandbox/transaction guarantee is implied.

### B02 Enter translated body / install library vocabulary

- **Keep/extend:** enclosing lexical bindings and explicit application facts;
  extend scope/opening in lexical order, with local shadowing.
- **Create:** body translation work; word/callback descriptor and source origin.
- **Complete:** restore outer generator work. A native result annotation creates
  a word; ordinary Mua `function`/host closures retain their meaning.
- **Library lifetime:** shared source type identity is allowed; cached Nua words
  and native representation work must be associated with the active module.

### B03 Supply fewer than all requirements

- **Keep:** word identity/body/requirements and earlier static supply.
- **Create:** new supply after requirement coercion.
- **Complete:** return a word with fewer requirements, **without evaluating its
  body**. This does not promise argument evaluation/coercion is effect-free.
- **Reject:** dynamic/borrowing incomplete supply; no runtime closure fallback.

### B04 Saturate and evaluate in place

- **Keep:** caller evaluation, storage/place identities and residual destination.
- **Create:** invocation/round lifetime, bound arguments, owned exits/snapshots.
- **Evolve:** caller path knowledge and ordered residual work; known computation
  need not emit anything.
- **Complete:** reconcile invocation result/exits, expire snapshots/lifetimes,
  restore active/region stacks. A nested invocation cannot consume outer matches.
- **No destination:** host application requires static arguments and no residual
  effect; reject rather than secretly create an export.

### B05 Fork branch and reconcile predecessors

- **Keep:** input identity graph, immutable values, fresh-ID capability.
- **Create:** arm block, shallow path-state copy, path identity and scoped facts.
- **Complete each arm:** return block/end-state/dead/result; block-owned ordinary
  cleanup happens before its path is handed back.
- **Join:** ignore dead paths; zero live paths kills continuation, one forwards
  its state; multiple paths agree or materialize their own pending values.
  Owner movement may require release on the other live paths.
- **Output ownership:** parent reconciliation retains patch rights to predecessor
  blocks until stores/releases are placed before terminating transfers. Joining
  a reference can expose another place and require a second reconciliation step.

### B06 Return / land an immediate match

- **Keep:** invocation's result contract and caller-owned state identities.
- **Capture:** returned value/payload before stores/releases that could change it.
- **Complete:** reconcile producer paths; then evaluate selected handlers and
  reconcile handler results. Equal known payloads can remain static; differing
  payloads require storage. End frame-owned lifetimes.
- **Reject:** nonexhaustive/invalid handlers, incompatible inferred runtime
  results, own-local borrows escaping. A return leaves its invocation, not an
  enclosing user activity's completion code.

### B07 Discard/retry one evaluation attempt

This records the current protocol, not proof that every cause requires it.
Derivation §3 traces mode promotion, state discovery, failed header agreement and
boundary sharing separately.

- **Keep:** word/body, designated target frame, fresh identity supply and
  independently built functions; explicit widening/escape/adoption feedback.
- **Restore:** snapshot-owned block suffix, abstract contents/dead state, locals,
  attributed command suffix, logged escapes/endings and selected storage holdings.
- **Invalidate:** checked/index reuse via epoch; expire abandoned invocation
  registrations; unwind regions/active stack separately from data rollback.
- **Complete:** replay at broader knownness/storage mode, never with dangling
  patch rights or a value naming discarded local storage.
- **Not promised:** rollback of arbitrary Lua effects or every mutable field
  reachable from a place/function. See the selective-undo ledger below.
- **M1 transport proposal (D03), freeze reopened:** preserve the current targeted
  transport provisionally; do not implement the withdrawn new unwind protocol or
  a coroutine redesign. Compiler-owned guards need not retain their current shared/
  stack placement; host resources are not discardable compiler data. Only the live
  target retries; known-tail work follows B08. See derivation §§8/9.

### B08 Continue a known round / form a residual back edge

- **Known tail:** finish old round lifetime, pass new arguments and continue;
  this is not necessarily a discarded attempt.
- **Residual loop:** generalize changing known values monotonically; keep proven
  invariant record fields; initialize loop storage outside the loop.
- **Edge:** validate/capture incoming values and transfer surviving holdings before
  cleanup invalidates them; perform simultaneous assignments (cycles use temporaries)
  and transfer to the owning loop label.
- **Refuse or change boundary as specified:** incompatible reference targets or
  changing scoped provenance. Current alias-state discovery also restarts, but a
  write alone does not prove a header invariant false: the body can restore it.
- **Separate joins:** header facts must admit the initial and continuing inputs;
  exits establish the following continuation's contents/holdings, including zero
  iterations. A change only on `break` need not invalidate a header invariant.
- **Nested ownership:** an inner exit is not an outer back edge. The same place can
  have different header facts at the two loops; outer rejection discards accepted
  child work too. Recover entry facts before mutation, not from the new contents.
- **Accepted identity rule:** direct access and aliases to a carried native local
  observe the same current contents in known and residual rounds (W02). The known-
  round copy discrepancy remains unfixed. Earlier bound values, explicit value
  copies and lifetime rules are unchanged; the rule does not choose a representation.

### B09 Materialize / invoke a native boundary

- **Keep:** word identity and all static arguments admitted by boundary rules.
- **Create:** shared specialization function identity/signature, fresh evaluation
  and abstract parameter origins; no inherited caller contents map.
- **Call:** materialize reference arguments; transfer owner holdings; assign
  result storage; invalidate lookup assumptions and apply borrow/move summaries.
- **Complete:** result contains only value/storage/borrow information that the
  caller can own. Known arguments do not reappear as generic runtime parameters.
- **Reject:** inaccessible caller locals, unsupported suspension, foreign ABI
  ownership/borrow contracts. Foreign/indirect calls have no inferred callee
  summary. Explicit `call` must not be bypassed by a warmed in-place memo (G03).

### B10 Rebuild a materialized-function attempt

- **Keep:** accepted outer definitions and explicitly recorded move/placement
  feedback for the named target.
- **Discard:** that attempt's function definitions and descendants/key entries;
  create a new builder/body/signature substitution, not a caller-state clone.
- **Complete:** publish only accepted body/summaries/dependencies; unfinished
  recursive references obey explicit assumptions and retry protocol.
- **Reject:** nonconverging placement (current bound 16 rebuilds), unknown signal,
  or diagnostic. Frame rollback and whole-function rebuild must not share one
  indiscriminate “reset everything” operation.

### B11 Spawn / capture

- **Keep:** known host/native inputs admitted as static facts; task scope handle.
- **Create:** resumable function and capture parameters; copy dynamic sendable
  values at spawn, including expression leaves discovered after staging.
- **Complete:** captures belong to task; array views address task-owned copies;
  start only after capture assignment.
- **Reject:** shared parent storage, unsendable captures, invalid slot placement.
  Do not generalize this into arbitrary native closure environments.

### B12 Lending activity / wait / blocking body

- **Lending:** create a token, evaluate body, end lending before handing result
  outside; reject a result that depends on the ended token.
- **Task scope:** own channel/pool lifetime and end-scope wait; mark scope ended
  even when body fails. This is not a staging checkpoint.
- **Wait:** invalidate lookup assumptions; residual task suspends or plain caller
  blocks. Completion yields its typed result under task/channel/slot contracts.
- **Blocking body:** shares suspended task frame; restore compiler's outer block
  and blocking marker on failure. Nested blocking does not create another task.

### B13 Complete/prepare a residual program

- **Require:** invocation construction complete; declared bodies and recursive
  summaries available (lazy runtime materialization may extend reachability).
- **Order:** reachability → task-global check → cleanup → layout → stack/call
  planning → yields/exit restoration → prepared view.
- **Own:** each analysis's facts/output. No inherited export-view proof; no
  source-type layout mutation. Repeated preparation must not duplicate exits/yields.
- **Invalidate:** changes to root/ABI/body/dependency graph must invalidate affected
  proof; current count/boolean guards are not a sufficient new cache contract.
- **Consume:** C and gccjit receive the same semantic preparation, not separately
  implemented ownership/specialization algorithms.

### B14 Backend / foreign world / native result

- **Keep:** prepared semantics, declared ABI, platform/tool options as explicit input.
- **Create:** backend unit/function work, probe requests, artifacts and owned
  native context/results. Backend names do not become source identities.
- **Complete:** release build contexts/resources; preserve code/result keepalives
  for callable lifetime; external errors remain failures with evidence.
- **Reject:** unsupported ABI/backend forms; no silent fallback. Experimental
  direct-backend limitations stay explicit. Probe compilation is an external
  effect, not a harmless schema-loading test.

## Selective-undo and evidence ledger

This closes the earlier map's broad question into named categories. **Observed
retention is not a correctness proof.** G01 identifies the remaining safety audit;
D02/D03 choose replacement construction/transport, not new native semantics.

| Category | Current frame retry behavior | Replacement obligation |
|---|---|---|
| Code/locals/path contents | Truncate output/locals, restore shallow state/dead | No live output or value may reference abandoned local/command structure |
| Expression ownership/lazy holes | Emit copies children; invocation expiration removes registrations; holes may have been patched earlier | Prefer producing requirements instead of tentative ancestor patches; where a surviving patch is needed, own its validity/undo and keep no discarded references |
| Shared place escape marks | Undo entries appended to `escapes`; other paths may share an earlier escape | Restore only changes owned by attempt; pending stores still belong to their predecessor |
| Borrow ending log | Reverse later endings and holder detachments | Earlier valid borrows restored; later invalidations must not disappear |
| Token creation/stored-view unions/projection caches | Not universally snapshotted; multiple holders carry shared attachments | Distinguish stable identity/conservative union from attempt-owned references; never assume shallow state copy isolates these |
| Stack holdings | Restore live/extra/result/claim sets and current owned list; unregister new slots | No double release, lost holder or claim to discarded storage |
| Lookup/index caches | Epoch advanced; maps can remain populated | Stale entries unreachable by validity predicate; do not reset epoch to revive them |
| Active/region/frame stack; temporary guards | Restored by surrounding control code, not snapshot alone | Every completion route restores dynamic bindings, including outward-targeted signals |
| IDs, native versions, slot serials, memory clock | Monotone; not rewound | No reuse that aliases a surviving identity/version; gaps are allowed |
| Allocation ordinals/spans and arena events | Retained within builder across frame rollback; fresh builder on function rebuild | Association with result/tenant plans must remain valid; conservative dead events must not authorize unsafe placement |
| Function effects, result/call/owner/growth sites | Not part of frame snapshot; construction probe finds one retained call operand naming a removed caller temporary | Caller owns each occurrence; reverse indexes cannot outlive that ownership. Separate justified feedback/definition dependencies from discarded IR-bearing evidence |
| Recursion/widening/placement feedback | Explicitly retained by their owning protocols | Only evidence for the named target crosses attempts; convergence and invalid combinations specified |
| Independently built functions | Preserved by frame rollback; descendants discarded by containing function rebuild | Dependency lifetime belongs to graph construction, not caller block suffix |
| Known-result memo | Builder-wide; not in snapshot; lookup currently precedes explicit-boundary handling | Revision 2 proposes omitting it; materialized-definition sharing and path-valid lookup reuse remain distinct (G03/G04) |
| Profiles/errors | Abandoned stream entries cleared; stable indices retained | No retained abandoned IR; diagnostics still identify source/application; no success report after rejection |
| Lua/module/native external effects | Not rolled back as a general transaction | Never promise replay purity/sandboxing the host language does not provide |

## Lifecycles and invalid combinations

These are **recommended logical phase distinctions**, not new public types yet:

```text
word + partial supply ──saturated──> invocation
                                      │
                    ┌─────────────────┼───────────────────┐
                    ▼                 ▼                   ▼
                 complete       retry with feedback     reject
                    │                 └──> new attempt    │
                    └──────────── owner completes ────────┘

materialization request → registered identity / building body
                              │ recursive references allowed under policy
                              ├── retry → discard attempt, retain named feedback
                              └── complete → finished body + summaries
                                              │
                                    exact reachable-view preparation
                                              │
                                           backend input
```

Prohibit: a finished block with unresolved payload holes; a residual read naming
another function's uncaptured local; a returned borrow of the invocation's own
local; a moved owner still scheduled for unconditional release; a completed native
call interpreted with an unfinished-summary default; an old prepared view reused
for different ABI roots; or a nested rewrite replacing its parent's output list.

A child's return is only the first handoff: parent acceptance adopts its output
and obligations, and publication checks their closure. A complete callee does not
publish its callers or make their temporary operands persistent. M1 must check
these graph/binding edges even though native owner allocation is excluded.

A generic context object with inherited/accumulated/evolving slots would obscure
these distinctions. Prefer small states named for their contents and activities
that explicitly own setup, output and completion.
