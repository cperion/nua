# Scenarios, evidence and freeze review

Part of the [review surface](README.md). This page distinguishes inventory
coverage, current-code evidence and replacement decisions. **The overall checked
storage direction is now approved; the complete replacement is not frozen.**
Tests are evidence, not authorization by themselves.

**Revision 5:** [checked storage](../checked-storage.md) records the accepted choices,
updated cost contract, safe Nua library witness and focused terminating-path fix.
Two reference-result requirements remain failing checks; region realization and
partial-move cleanup remain proof obligations. No native compilation was run.

**Revision 4 history:** [storage derivation](storage-derivation.md) integrates logical
allocations, destinations, transfers, reclamation and rejected construction.
Six [staging-only cases](storage-probe.lua) completed; they expose result-placement
rebuilds and a result-to-element no-copy question, not replacement acceptance.
The user approved careful design work, not a freeze or compiler implementation.

**Revision 3 history:** start with the [problem-first derivation](derivation.md), not the
rows below. After the W01–W03 derivation, both Mua guides were reread in full.
Section 6 now prefers producing snapshot requirements before assuming ancestor
edits need undo. Section 9's review withdraws the subsequent private-unwind
recommendation: the probes did not compare completion ownership fairly or prove
that retaining Lua hooks requires error transport. The scoped M1 proposal now
retains the existing targeted transport provisionally rather than redesigning it;
it is not approved and does not select coroutines. Sections 6/8 state the handoffs
and milestone. Revision 1's observations remain unchanged.

## Walk the model before choosing files

### W01 — known supply, dynamic branch, mutable local

Schematic Nua input (not a newly executed listing):

```text
choose_increment(condition: Bool): U32
    local amount: U32 = 10
    if condition then amount = 20 end
    return amount + 1
```

| Point | Application/evaluation | State/output obligation |
|---|---|---|
| Word declaration | R04 requirements/body exist | No native function or body execution solely from declaration |
| Known condition | O04/O06 saturate; O16 selects one arm | Result can be known 21 or 11; no need to build the other arm |
| Dynamic condition inside an export | Same body evaluates in caller | Initial contents of the one local identity are pending 10 |
| Branch | New predecessor blocks, forked contents | True arm pending 20; false arm pending 10; shared place identity |
| Join | Reconcile predecessors | Different contents require each live arm's own store, not a store of one arm's value after the join |
| Return | Reify joined contents and add 1 | Current path reads materialized storage; no helper function for ordinary word application |
| Cleanup | May reshape finished control flow | Shape may improve, but cannot substitute for correct staging or change effects |

**Rejection variation:** leave `amount` uninitialized on one live predecessor.
The continuation must not inherit initialization from the other arm. A dead
predecessor, on the other hand, must not poison the sole live path.

**Mutation variation:** bind an earlier read, then write the local. The bound
value must denote the earlier contents; lazy snapshot placement precedes the write.
Repeated saturated application must repeat its state effects (G04).

Witnesses: `tests/loop_adoption.lua`, `tests/immediate_matches.lua`,
`tests/errors.lua`; focused branch/alias cases are needed as independent state
checks in the rewrite, not only generated-C text comparisons.

### W02 — an alias writes a loop variable

Use `examples/loop_adoption.nua` and `tests/loop_adoption.lua` as the concrete
source corpus. A record has an invariant field and a changing field; a reference
or captured name writes the latter inside a dynamic loop. The sequence below is
**the observed strategy**, not a requirement to reproduce each restart:

1. The initial round sees known contents; syntactic state can use round copies,
   while adopted state uses its original place.
2. The alias write reveals state not named in the loop's original parameter list.
3. O17 sends adoption/escape feedback to the **outermost affected loop**, not
   necessarily the most recent word application.
4. B07 discards that attempt's output and restores path/ownership state.
5. Replay adopts the original place where legal, keeps invariant fields known,
   and gives changing fields loop storage.
6. Exposing the address may instead require escape, with initialization **before**
   the residual loop. Back-edge moves are simultaneous, including swaps.

The required obligations are original place identity, header agreement over initial
and continuing inputs, and separate exit establishment. Derivation §3's
[evaluator traces](evaluation-trace.lua) show that discovering a write does not
necessarily invalidate an entry fact, and that an exit-only change is distinct
from a changed back edge. Candidate simplifications must preserve those facts,
not simply reduce the number of observed restarts.

**Accepted language decision — user: "lets adopt that rule".** Direct access and
references to a carried native local observe the same current contents in known
and residual rounds. Syntax §6.4 now states this rule; distinct value copies,
by-value word arguments, task captures and earlier bound values are unchanged.
This is approval of that semantic rule, not a rewrite freeze or implementation
approval for D01–D06.

**Outstanding implementation discrepancy:** the additional
[boundary probes](loop-boundary-probes.lua) assign through a syntactic loop local
and read through a previously taken, read-only reference. With one known round,
assignment changes the round copy while the alias reads the original; the staged
result is `0`, but the accepted rule requires `1`. In the completed dynamic loop
both accesses use the original place; no native result was measured. The probe
and raw observations remain unchanged. Correcting this is a deliberate behavior
change, not a claim that the old compiler already implements the adopted rule.

**Future acceptance obligations:** the witness must yield `1` with one known round
and with runtime `n=1`; direct reads must also observe writes through aliases.
Check nested rounds and preserve the value of a read bound before the mutation.
These obligations have not been run as acceptance checks.

**Rejections:** incompatible reference target on an explicit loop edge, or changed
scoped borrow provenance. Failure to qualify for adoption is not automatically a
program rejection: the existing escape/ordinary-storage rules can apply where
legal. Do not silently create a different place that existing aliases no longer
name.

**Completion witness:** abandoned locals/statement graphs are collectable while
an independently materialized helper remains live. `tests/staging_retention.lua`
checks that distinction; its current fixture invokes compiler preparation, so it
is not advertised as a zero-work schema-loading test.

### W03 — return an owner, inline and materialized

Use `examples/nested_owners.nua` and the owner-result cases in
`tests/errors.lua` / `tests/fuzz/storage.lua` as sources to select focused fixtures.

- **Inline:** invocation creates a caller-owned destination. Each return
  constructs/moves into it; no native header transfer is required merely to return
  from the word. Join releases a still-held source on a path that did not move it.
- **With `call`:** known inputs still specialize the body. Caller supplies result
  storage; callee's returned header names that storage. Current placement discovery
  rebuilds functions, not just frame output. Revision 4 proposes logical allocation
  operands and result requirements before physical assignment; retaining those
  rebuilds is not itself a semantic obligation.
- **Nested container position:** holder/position lifetime and quiet-window
  placement matter; not all independent-looking owners have independent arenas.
- **At completion:** destination retains its holdings, sources are unusable as
  owners, and normal/early exits release exactly what each path still owns.

[The detailed walk](storage-derivation.md#3-work-the-two-live-owner-example-through-completion)
separates one receiving place from simultaneous candidate storage and the possibly
larger reclamation extent. The new probe observes one result stack for known true,
two for a dynamic flag. An element accepts the known result as an arena tenant
after reconsideration; the dynamic result fails tenant eligibility and source
reading identifies the copy path. Revision 5 resolves that call-result contract
explicitly: cross-position relocation is permitted, while ordinary moves/returns
remain no-copy. This is neither a hidden
fallback nor a new program refusal.

**Rejections:** returning a borrow of the invocation's own local; moving an owner
out through an exported `Ref` without a foreign caller protocol; unsupported
recursive destination/growth arrangements. Keep Nua's specified cross-position
copying distinct from an implicit copy substituted for an ordinary move.

### Remaining scenario obligations

| ID | Successful result / state obligation | Refusal or failure obligation | Existing witness starting points |
|---|---|---|---|
| W04 Application/call | Partial supply does not run body; saturation uses all known inputs; repeated explicit call shares a specialized boundary | Dynamic incomplete supply; no native destination for effects; memo must not erase `call` | `examples/spec_core.nua`, `examples/boundary.nua`, `tests/formatter_application.lua`; G03 |
| W05 Return/match | Equal known payload stays static; differing payloads get one landing/result protocol; nested invocation owns its handlers | Missing/extra handlers, wrong inferred result, cross-invocation landing | `tests/immediate_matches.lua` |
| W06 Borrow/check/iteration | Whole/content/element/position dependencies differ; lookup reused only on valid path/epoch | Ended/scoped escape, structure change during iteration, stale lookup after call/wait/retry | `tests/borrowed_views.lua`, `tests/map_types.lua`, `tests/errors.lua` |
| W07 Task/capture/wait | Known capture baked, dynamic capture copied, array view rebased; block shares suspended frame | Parent storage capture, unsendable/invalid slots, hidden unsuspendable call, unsafe task globals | `tests/task_globals.lua`, `tests/errors.lua`, task examples under `examples/` |
| W08 Types/modules | Same parameterized identity where promised; nominal same-name records remain distinct; library words refreshed by compilation | Invalid recursive by-value type; stale module/type method; nested compilation | `tests/modules.lua`, `tests/map_types.lua` |
| W09 Preparation/layout | Exact roots/ABI view, complete dependencies, source type fields unchanged, one set of exit/yield rewrites | Reuse proof for another export view; lose pointer origins before task check | `tests/storage_layout.lua`, `tests/storage_boundaries.lua`, `tests/task_globals.lua` |
| W10 Numbers/ABI | Width/signedness/F32 rounding/varargs agree across known and native execution | Known UB, invalid conversion, opaque layout/unsupported ABI | `tests/fuzz/fuzz.lua`, `tests/errors.lua`, `examples/spec_core.nua` |
| W11 Family/inspection | Each representation printable, identity edges visible, each pass complete, output copies own structure | New kind missing from a pass; invalid fields/lists/phase; generic recursion through identity cycles | New rewrite checks required; current ad-hoc `__tostring`/walkers are not a full witness |
| W12 Completion/resources | Restore loader/active/output bindings; abandoned graphs released; native result remains callable while owned | Original failure swallowed as retry/skip; nested rewrite corrupts parent output; freed code pointer | `tests/modules.lua`, `tests/staging_retention.lua`, native harnesses; new focused activity checks required |

## Fresh evidence: three cheap probes, no native compilation

These ran directly against the baseline Lua evaluator or synthetic IR. They did
**not** emit C, run a C compiler, load a runtime library or invoke gccjit. Exit
success of a probe only means it obtained the observations; the observed behavior
in G02–G04 does **not** satisfy the intended preservation contract.

The [probe source](probes.lua) is tracked beside this review. To reproduce all
three from the repository root, run
`luajit docs/design/compiler-inventory/probes.lua`. It prints observations rather
than asserting that the baseline's incorrect behavior is an acceptance criterion.

### G01 — retained construction references; correctness audit still open

Source reading establishes exactly what snapshot/rollback restores and what it
does not; the [selective-undo ledger](state-and-boundaries.md#selective-undo-and-evidence-ledger)
classifies the responsibilities. Allocation ordinals, arena history, summaries,
call sites and some place/token attachments are not collectively a checkpointed
transaction. This is no longer an unnamed “miscellaneous builder state” gap.

A subsequent [construction probe](construction-probe.lua) adds one actual scalar
staging observation: after one loop rollback, two functions and two residual calls
remain, while the callee's `call_nodes` has four entries. One metadata operand reads
a temporary removed from the caller's locals; the residual bodies have no such
read. `Builder:emit` copies expressions, so the probe checks removed-place references,
not equality between metadata and emitted call tables. The raw output is retained
in `build/logs/compiler-construction-probe-v1.txt`.

This establishes a retained-reference edge across construction owners, **not a
native miscompilation**: preparation and native execution were not run. It makes
call-site/index ownership an M1 obligation even without resizable native owners.
Keeping a valid callee definition does not justify keeping discarded callers.

Revision 4 adds owner-placement observations in [storage derivation §8](storage-derivation.md#8-observations-and-checks-not-replacement-acceptance).
These demonstrate current construction/placement paths, not safe allocation
correspondence across arbitrary retries. The candidate is to derive placement
from accepted logical occurrences so rejected attempts need not keep ordinal plans.

**Remaining freeze question:** approve the replacement rule that only stable
identities and explicitly justified conservative feedback survive a discarded
attempt; output-bearing references must belong to accepted construction or have
an undo obligation. A correctness proof for every current retained attachment
has not been completed. Do not claim the old protocol is safe merely because an
omitted field appears monotone, or that every omission is a bug.

**Disposition recommended:** freeze the explicit ownership/validity requirement,
not an obligation to reproduce the old shallow snapshot's omissions. Before a
migration milestone moves an attachment, its row must say whether it is restored,
invalidated, retained as conservative evidence, or owned by an outer activity.
Bindings, lifetimes, guard restoration, call-site indexes, definition dependencies,
allocation descriptions and owner move/result summaries all constrain the core now.
An implementation milestone is not selected. Physical numbering may be deferred;
semantic storage and release obligations may not be excluded from the design.

### G02 — residual effect vocabularies disagree

Source anchors: `stage.h.EFFECTS`, `memory.EFFECTS`, `cgen.dead_stores`,
`inline_temps`, `same_expr`, `hoist_common`. Several cleanup checks still name
`rt`; producers use `rtcall`. Indirect calls also need explicit coverage.

Probe: construct a Unit function containing `let unused = <effect expression>`
and `ret`, with otherwise identical `call`, `calli`, and `rtcall` expressions,
then run only `G.cleanup`. No expression is executed.

```text
call commands=1 remaining=expr
calli commands=0 remaining=none
rtcall commands=0 remaining=none
```

Raw source/output: `build/logs/inventory-cleanup-effects.lua` and `.txt`.

**Disposition recommended:** closed operation vocabulary and explicit ordered
execution sites, separate from reusable value recipes (derivation §5). Unused
results do not erase calls. Dependency/movement analyses still need complete,
purpose-specific policies; not every arithmetic expression is safe to speculate.
Do not preserve unknown-tag fallthrough or the legacy `rt` spelling as a
compatibility path. This is a synthetic-IR observation, not a claim that every
library use is currently removed.

### G03 — a warmed known result bypasses explicit `call`

Source anchor: `Builder:apply` consults `self.memo[key]` **before** handling the
word's `boundary` marker.

Probe: export a zero-argument U32 word whose body calls `add_one(2)` through
`S.boundary`. In the warm case first evaluate the same word/argument normally.
Count staged functions and direct call expressions before preparation.

```text
warm=false functions=2 calls=1
warm=true functions=1 calls=0
```

Raw source/output: `build/logs/inventory-call-boundary.lua` and `.txt`.

**Disposition recommended:** preserve syntax §3.9 and the user's model: explicit
`call` inside residual evaluation requests a boundary even with known arguments;
prior evaluation must not change that. Host compile-time `call` still runs in
place. Record this as a discrepancy to correct, not a new exception to `call`.

### G04 — no emitted code is not proof of no evaluation effects

Source anchor: after in-place application, `Builder:apply` memoizes a known
result when arguments are static and the current block length did not grow.
But native writes can change pending contents without emitting a command.

Probe: an exported word creates a U32 local counter at zero, then a word
`bump(step: U32): U32` capturing it, storing `counter + step` and returning the
new contents. Apply `bump(1)` twice, then inspect staged counter contents.

```text
first=1 second=1 counter=1
```

The application/mutation contract requires first 1, second 2, counter 2.
Raw source/output: `build/logs/inventory-known-memo.lua` and `.txt`.

**Disposition recommended (revision 2):** omit general known-result memoization
from the initial evaluator, instead of constructing a purity system to justify
it. Native function sharing by specialization key remains essential; primitive
folding, type interning and path-valid lookup reuse are also distinct. Any later
result cache needs a proof covering the observations/effects it skips and measured
benefit. “Same block length” is not that proof; arbitrary host upvalues make a
blanket proof especially inappropriate.

These gaps require dispositions, not an opportunistic patch campaign during the
inventory task. The ignored logs preserve the raw experiments; the descriptions
and outputs here preserve the review evidence in version control.

## Decisions needed to freeze the replacement contracts

The semantic centre is already agreed. These are consequential **implementation
architecture** choices still proposed; the table is not a request to renegotiate
curry/evaluate/residualize/explicit-call semantics. W02's loop-alias rule is an
accepted language decision. The overall checked-storage direction is also accepted;
exact representation/completion mechanisms and replacement milestone scope remain open.

| ID | Recommendation | Alternative/consequence to reject or choose deliberately |
|---|---|---|
| D01 Front-end/evaluator substrate | Retain Mua AST hosting and staged Lua closures for the first rewrite; make their input/result/state edges explicit | Direct closure emission or another evaluable syntax representation is a separate frontend redesign, not required by families |
| D02 Construction and phase ownership | Derivation §6 handoffs plus storage derivation §§4/7: logical allocations, destinations and release descriptions travel with owned output. Distinguish semantic completion from exact-view storage realization and backend readiness | Compiler-record transfer cannot extend native lifetimes. Late realization must remain Nua, preserve original observation sites and close its dependency graph; no generic transaction mechanism |
| D03 Control and retry | **M1 proposal; freeze reopened:** owner-scoped header re-evaluation; no transport redesign. Provisionally retain current targeted private transport where needed, checked results between cooperating activities (§8/§9) | This explicitly retains an implementation technique, not a guide endorsement. The withdrawn acknowledgement/unwind framework stays withdrawn; no coroutine choice or silent host-protocol change |
| D04 Provenance | Carry source origin plus invocation context through residual construction, with explicit synthetic origin; preserve current diagnostic site choices | Promise full column spans/native source maps or rely forever on Lua stack inspection alone; either is a separate decision |
| D05 Closed domains/open vocabulary | Derive checked shapes from problems: header place, holding/lifetime, allocation occurrence, receiving destination, borrow dependency and reclamation extent must be distinguishable, without requiring one record per concept. Preserve path facts, lazy bindings, ordered sites and open Nua libraries | A physical arena index is not a shared-position semantic mode. W02's same-place rule remains accepted; neither whole heap modeling nor a scalar-only core follows |
| D06 Evidence and caching policy | G01 explicit retention and placement over accepted occurrences, with correspondence proofs where feedback really crosses attempts; G02 ordered effects; G03 boundary shape; G04 omit general result memo. W03's cross-position relocation cost is now approved | Reproduce old cache/snapshot predicates, conflate function sharing with skipped evaluation, silently copy an ordinary owner move/return, or treat staging success as replacement acceptance |

These recommendations establish contracts and migration obligations, not a final
module tree or commitment to one immutable/persistent collection implementation.
Backend-local C reader/direct assembler internals retain their existing edge
contracts unless a later reviewed milestone explicitly takes them on.

### Historical withdrawn scoped-freeze proposal: M1

[Derivation §8](derivation.md#8-what-this-changes-and-what-remains-to-decide) states
the proposed deliverable and exclusions. **The scoped freeze is withdrawn.** After
“ok go b”, the assistant recorded approval, but the user immediately challenged
freezing the scope without an integrated memory model and asked why intended
features would be rejected. No compiler implementation preceded that challenge.
The scope and memory-model integration must be settled, not treated as accepted.
Temporary unsupported diagnostics were intended to prevent silent old-evaluator
fallback; they are not language restrictions or a reason to exclude those features
from the core design. W02's language rule remains accepted separately.

| Contract to freeze | Evidence required before declaring M1 complete |
|---|---|
| Mua AST hosting and online staged closures | Source-based known/mixed examples exercise supply, in-place evaluation and native materialization, not just helper APIs |
| Owned child output, parent adoption and publication | Accepted child then rejected parent leaves no leaked bindings/sites; earlier accepted sibling work remains; publication refuses unresolved or discarded operands |
| Deferred read requirements at original sites | Capture dominates the relevant uses; no capture when safely unnecessary; return/expiration does not extend a native loan or accept a stale unbound read |
| Same-place loop semantics and separate header/exit checks | W02 requires `1`; known prefixes remain; nested restoration, zero-iteration/exit-only state, simultaneous edges and escape placement are inspected |
| Caller-owned call occurrences; separately reusable definitions | A callee can survive caller rejection without its discarded operands/index entries; unfinished recursive dependencies are not mistaken for complete definitions |
| No general result memo; ordered execution sites | G03 explicit sharing survives known warm-up, G04 repeated mutation occurs, G02 direct/indirect/runtime effect policies remain complete with unused results |
| Shared prepared contract, with explicit subset refusal | New checked output reaches C text without old evaluator fallback; unsupported source/IR forms refuse with origin, not unchecked defaults |
| Provisional existing nonlocal transport, not its redesign | Targeting and exactly-once compiler-guard completion on normal, reconsidered and failed paths; preserve genuine failure identity/provenance |

These were proposed implementation proof obligations, not tests already passed.
The exclusions in that proposal are not current design boundaries. Revision 4
requires memory integration before selecting an implementation milestone; task
and suspension contracts also remain obligations, not presumed scalar variants.
The current budget does not authorize a native campaign.

## Readiness checklist

### Inventory work done in revision 1

- [x] Responsibility-centred scope and source-area coverage ledger.
- [x] Core representation domains, current variants/payloads, identity edges and
  phase-only/consumer-only spellings given explicit dispositions.
- [x] Operation results/effects, candidate passes, defaults and traversal order.
- [x] State creators/roles/validity/owners; normal and exceptional boundary paths.
- [x] Separate frame retry, tail continuation, function rebuild and host effects.
- [x] Concrete branch/loop/owner walks and positive/refusal/state witnesses.
- [x] Current/required/proposed behavior separated; cheap contradictory evidence
  recorded without changing compiler code or pretending it passed.

### Problem-first work done in revision 2

- [x] Derived identity/path/continuation obligations from a mutable branch.
- [x] Extended to alias-written loops, invariant fields and address escape.
- [x] Distinguished logical owner-result destination from physical allocations.
- [x] Proposed no general result memo, explicit execution sites and reused joins.
- [x] Walked earlier-read/nested-retry through the then-proposed narrow undo,
  including accepted-child/failed-parent completion; revised below, not frozen.
- [x] Challenged the core against W01–W12 without claiming implementation proof.

### Guide reflection in revision 3

- [x] Read both guides in full, plus Mua syntax and the complete Lisp example.
- [x] Revisited snapshot placement as produced requirements, with child/parent
  retry ownership; kept narrow undo as a justified alternative, not the default.
- [x] Made D03's outcome/transport conflict explicit rather than attribute private
  error-based unwind to a guide that rejects ordinary alternatives as errors.
- [x] Distinguished pure content agreement from effectful state establishment;
  specified inspection and completion evidence for the first executable milestone.
- [x] Ran [standalone retry probes](retry-probes.lua): **15 Lua-mechanism assertions
  passed**, covering cooperative returns, opaque assignment hooks, yield/resume,
  collected-coroutine abandonment, nested-target unwind, error identity and
  intercepted-transport refusal. These are not Nua acceptance checks; no native
  compiler was invoked.
- [x] Reviewed and withdrew the subsequent unwind recommendation; separated current
  cleanup placement from required hook/lifetime semantics and classified requests
  before selecting transport.
- [x] Ran [ownership countermodels](retry-owner-probes.lua): **9 assertions passed**.
  An outer driver completes owned work without exception transport; a host-owned
  coroutine exposes a routing gap. These bounded models do not choose a substrate.
- [ ] Settle D03 within the reopened milestone contract. No transport redesign is
  proposed; no existing transport defect is established by the probes.
- [x] Decoded ten actual evaluator cases with [staging-only traces](evaluation-trace.lua):
  known rounds, mode-only promotion, widening, shared recursion, alias discovery,
  restored fields, exit-only changes, escape and an earlier bound read. All ten
  staged successfully; no preparation/native acceptance was run.
- [x] Identified candidate simplifications from those distinctions, not from the
  spelling of current signals. No equivalence of a replacement is claimed.
- [x] Stated the loop-completion candidate: entry/header distinction, late state
  discovery, continuing-edge checks, separate exit establishment, nested ownership
  and earlier-read obligations. Neither a dependency-repair graph nor a universal
  retry subsystem is proposed.
- [x] Four additional staging-only boundary cases completed after fixing probe
  instrumentation. Nested restoration preserves an outer invariant while the inner
  header is dynamic; read-only aliases exposed the W02 identity question.
- [x] User adopted W02's same-place rule for known and residual rounds. Updated
  syntax §6.4 and recorded the observed `0` versus required `1` discrepancy.
- [ ] Implement the accepted alias rule and its focused regression obligations
  after implementation approval; neither the compiler nor the old probe was changed.
- [x] Tightened child-return/adoption/discard/publication handoffs and binding
  lifetime requirements; traced a real callee index retaining discarded caller data.
  The one-program construction probe completed without preparation or native tools.
- [x] Proposed a source-to-prepared-IR/C-text scalar/record milestone with explicit
  exclusions, ownership proof obligations and no production fallback/cutover.
- [ ] Settle the user's memory-model and feature-exclusion objections before
  treating the replacement contract as frozen or proceeding with implementation.
- [ ] Validate the mechanisms in that scoped skeleton after approval. Earlier
  mechanical probes do not validate the replacement's state/ownership integration.

### Storage derivation in revision 4

- [x] Read Goose's memory specification and relevant implementation notes at a
  pinned revision; distinguished its invariants/restrictions from Nua's contracts.
- [x] Worked known/dynamic inline and materialized two-live-owner results through
  holdings, candidate storage, transfers and cleanup; proposed symbolic assignment
  rather than treating result-placement rebuilds as mandatory.
- [x] Distinguished semantic position from physical arena placement, result header
  from reclamation extent, and native release from construction discard.
- [x] Six real staging-only observations completed after two fixture corrections;
  raw failed and successful runs preserved. No preparation/native acceptance.
- [x] Revision 5: user approved cross-position result relocation; ordinary moves/returns remain no-copy.
- [ ] Close Nua-based realization of symbolic region captures/releases, including
  its possible effects on definition and planning dependencies.
- [ ] Complete move/loan, owner-loop and recursive/mixed-origin result arguments
  against this same description; preserve existing lifetime/refusal contracts.
- [x] Revision 5: overall integrated checked-storage direction approved, without reviving M1.

### Checked storage in revision 5

- [x] Record concrete approved choices and update syntax/architecture/memory contracts.
- [x] A generic safe Nua sparse-buffer witness exercises initialized cells and scoped borrowing.
- [x] Two library cases stage; five invalid lifetime/move cases are rejected as expected.
- [x] Correct trap-path completion; eight focused staging/IR checks pass.
- [x] Three recursive/mixed-origin cases stage; older-result growth is rejected.
- [ ] Reference-returning lookup: inferred matches reject valid Ref results.
- [ ] Reference storage guarantees: a joined shared-position Ref can lose its growth invalidation.
  The dedicated probe reports two gaps and exits nonzero, not a passing acceptance result.
- [ ] Close Nua region realization, mixed-origin cleanup and independently moved result fields.

### Required before declaring a freeze

- [ ] Review D01–D06 against the integrated memory model; amend inventories to record **accepted decisions**, not leave
  recommendations ambiguously binding.
- [ ] Accept/amend G01–G04 dispositions; identify which first milestone must carry
  the corresponding regression and state-obligation checks.
- [ ] Select a coherent end-to-end first milestone and its limits. It must exercise
  application/evaluation/residualization/materialization, not only convert helpers.
- [ ] Record an agreed replacement contract after resolving the objections above.
  The assistant's withdrawn freeze is not approval of the proposed exclusions.

## Validation policy for the later rewrite

During curation: source reads, documentation consistency, hand-built descriptions,
standalone Lua-mechanism experiments and tiny evaluator probes only.
**No compile-heavy suites** have been run here.

During implementation, after approval: family coverage/constructor refusals,
stable inspection, pure numeric/array checks, and narrowly scoped evaluation/
state/completion checks first. Test discarded work, nested output, identity
preservation and cache invalidation, not just numeric answers. Keep contracts on.

At coherent accepted milestones: relevant C/JIT/native agreement, rejection and
ABI/lifetime checks through the project's test entry points, within the user's
validation budget. Both backends consuming the same wrong IR is not independent
proof of staging correctness. Known evaluation shares machinery too; supplement
it with explicit expected results/state transitions and native numeric rules.
Missing platform libraries/backends or failing sanitizers must be reported
accurately, never silently converted to passes or skips.
