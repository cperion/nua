# Completion joins: proving an additional role is absent

This continues the [native-boundary experiment](compiler-boundary-experiment.md)
within the [completion proposal](compiler-completion.md). It closes that experiment's
original unequal-width witness, **not general completion normalization or a production
ABI**. The [join probe](compiler-join-probe.mua) reuses the boundary planner and its
independent storage ledger; it is not another evaluator or program representation.

**Subsequent update:** the [regional experiment](compiler-region-experiment.md)
closes the exchanged-component witness below with boundary-owned relations. Its
separate acceptance command now exits 0; the earlier exit-1 evidence remains intact.

## The original failure is closed

The source remains unchanged:

```text
left initially carries one position; right remains independently live
if flag:
    left = call argument_or_fresh(choice, move left)
else:
    keep left
observe/end left
observe right
```

`flag` and `choice` remain independent. The old `--unequal-components` command now
exits **0**, checking all **8 prefix/Boolean combinations**. The extra call footprint
already contains one reserved role. The planner moves its capture before the branch
and carries that position and original mark on both incoming edges. The branch
without the call acquires the unused reservation, not another field's obligation.
Ending `left` restores both positions; the later observation of `right` succeeds.
No new allocation, dummy role, cleanup tag, or source call is introduced.

The historical exit-1 evidence remains in
`build/compiler-boundary-probe/06-unequal-components.log` and
`build/compiler-boundary-probe/unequal-components.log`. It is not overwritten by
this milestone's runs under `build/compiler-join-probe/`.

## What justifies the extension

The finite acyclic analysis records visited instructions/edges and the selected
incoming edge of each join. These are **compiler facts about the existing IR**, not
runtime flags. A component's position/mark choices use the same edge selections as
its owner; resolving them does not independently union field alternatives.

For each missing completion slot, the experiment requires:

1. Every present alternative resolves to the same reserved role of this definition.
2. On every missing incoming path, that role's allocation/call site has not executed.
3. No earlier normalization has acquired the role on that path either.
4. Its original capture can dominate both the original use and the added operands;
   captures are instantiated only after their placement is decided.

Recording calls and previous acquisitions matters even when the role has no payload.
“No allocation happened” does not mean “nobody carries this completion obligation.”
Imported roles and genuinely different extra alternatives need further normalization;
the planner does not manufacture a common role or append a sibling's positions.

Existing component slots still carry correlated position/mark block arguments.
Additional slots use the proved-unused reservation. This works through nested joins:
a role introduced by an inner optional call can also be absent on the outer bypass.
The proof includes the inner join's acquisitions when considering later joins.

Captures and resets remain the ordinary [Nua words](compiler-completion-words.nua),
hosted by current Mua and `nua.front`, and instantiated into the same program family.
The helper-realization factory accepts a name namespace so independent activities
can compose their output without colliding generated identities. It does not
reimplement storage behavior in Lua or C. `nua.stage` is not loaded.

### Demand is not a completion exception

A first nested trial exposed a needless width constraint inside
`argument-or-fresh.leases_2`: its terminal owner join was being given completion
operands that nothing consumed. A native return already has the experiment's fixed
**incoming envelope plus fresh footprint** contract at its receiving caller.

The planner now propagates demand backward from native call arguments and receiver
resets through moves and edges. Only demanded owner joins receive hidden completion
operands. Source owner operands, lifetime checks, calls and the caller's full result
envelope remain. This is elimination of unused proof operands, not a way to omit a
needed reset or bypass a call contract. A separate witness forwards a normalized
join through another call *inside* a leased definition, where the operands are needed.

This demand set is finite and monotone over the existing SSA identities. That says
nothing about convergence of recursive completion widths or fresh-footprint growth.

### Hoisting also owns the exits it crosses

A capture moved to the receiving entry creates a reservation even on an early exit
that bypasses the join. The planner inspects exit paths too. If an exit uniformly
has not acquired that role, it emits the ordinary Nua restore there. It does **not**
weaken the ledger to forgive an uncompleted empty reservation.

An exit combining acquired and unacquired paths still needs edge-specific placement;
the current planner refuses that plan instead of inserting an unconditional second
reset. Cross-call trap unwinding and early owner returns remain open. The successful
early-exit witness here is a scalar return on a separate exit path.

## Focused evidence

Six witnesses execute **72 prefix/Boolean combinations**:

| Witness | Checks | Additional evidence |
|---|---:|---|
| Original unequal join | 8 | Three existing roles, no invented padding; unused role has no payload |
| Swap before unequal join | 16 | Independent swap/call/choice inputs; forwarded native calls reach three frames |
| Nested unequal joins | 16 | One-, two-, and three-position components; two optional fresh footprints |
| Join inside a leased definition | 8 | Normalized operands cross another call; capture authority remains outside |
| Retained-prefix unequal join | 8 | Returned data begins above a dead prefix; reset uses the original mark |
| Early exit before acquisition | 16 | Empty hoisted reservation is completed even when the join is bypassed |

Successful continuations observe the sibling after the other component's physical
resets. Exact native-call counts check that effects were not moved, duplicated or
flattened. Replanning compares complete root/callee output and checks source-body
construction counts: placement does not replay source or change accepted graphs.

Eight deliberately invalid plans/IR mutations are refused:

- padding from a surviving sibling;
- an additional position paired with another position's mark;
- an edge-local recapture after allocation, despite valid SSA dominance;
- missing normalized edge operands;
- omitted completion of an unused extended role;
- duplicate completion even when that role has no payload;
- loss of the earlier swap's owner/position correlation;
- an abandoned hoisted reservation at the early exit.

The independent boundary ledger is unchanged. Earlier overlapping-position,
original-mark, callee-authority, retained-prefix and borrow-ending counterexamples
remain. The earlier completion probe still rejects unrelated live growth clipped
by a reset; this milestone does not establish a general native growth contract.

## The subsequent exchanged-component failure, now closed

Now perform the argument-or-fresh call **before** the swap:

```text
left = call argument_or_fresh(choice, move left)  -- two-position component
if swap:
    exchange left and right                     -- right had one position
left = call relay(move left)
observe/end left
observe right
```

This source verifies. The vector planner's storage normalization exited **1** with:

```text
completion role is already active on the missing edge
```

The extra role belongs to the other field on that edge. It may protect live fresh
bytes; even when `choice` returns the argument, the sibling still carries the unused
role's completion. The successful absence proof above cannot be reused here.

`--exchanged-components` remains a **separate valid-program acceptance witness**,
not one of the eight invalid-plan rejections. It now explicitly invokes the
[boundary-relation experiment](compiler-region-experiment.md) on the original source
and passes all eight independent prefix/Boolean checks. This is a different candidate
contract, not a vector-planner fallback. No padding roles or sibling unions are used.

Its historical `build/compiler-join-probe/exchanged-components.log` remains exit 1.
That command ran the ordinary passing suite first, so the old log contains `PASS`
before its failure. The new exit-0 evidence is under `build/compiler-region-probe/`.
Neither experiment adopts a production ABI.

## Running and current status

From Nua's root, with the neighboring Mua checkout:

```sh
.local/bin/luajit ../mua/mua.lua docs/design/compiler-join-probe.mua
.local/bin/luajit ../mua/mua.lua docs/design/compiler-boundary-probe.mua --unequal-components
.local/bin/luajit ../mua/mua.lua docs/design/compiler-join-probe.mua --exchanged-components
```

Historical join-milestone results (the recorded logs are preserved):

- Join suite: **exit 0; 6 witnesses / 72 checks / 8 invalid-plan/IR rejections**.
- Original unequal-component acceptance: **exit 0; 8 checks**.
- Exchanged-component acceptance: **exit 1**, the unmet valid-program case above.
- Ordinary boundary suite: **exit 0; 6 / 24 / 13**, plus **1 invalid-source rejection**.
- Activities: **exit 0; 30 / 31**; original edge reclamation: **exit 0; 31 / 31**.
- Completion: **exit 0; 6 / 36 / 13**, plus **2 known Nua checks**.
- Final formatter and whitespace checks: **passed**. The formatter required a
  second pass to stabilize one nested constructor; the first check is retained.

Milestone logs are under `build/compiler-join-probe/`: `run.log`,
`unequal-components.log`, `exchanged-components.log`, `boundary.log`,
`activities.log`, `completion.log`, `edge-reclamation.log`, and `format-final.log`.
`format.log` and `second-format.diff` retain the intermediate formatting result.
The numbered logs preserve other observations, including the first nested constraint
and the first exchanged-component failure. Reviewed incremental diffs are alongside them.

This remains a bounded design experiment. It uses staged fixtures, synthetic owner
cells and whole-path enumeration, not real aggregate headers, scalable loop analysis,
recursive agreement, or platform storage bindings. No production compiler change,
dependency-pin change, C/libgccjit compilation, native Nua execution, or ABI adoption
is part of this milestone. These results did not establish the full replacement
architecture. The user's architecture-first requirement, including IR/activity infrastructure, has since been met by approval of [affine regions, completion and native tasks](region-completion.md). That is a new operational architecture, not retroactive validation by this milestone. The [regional follow-up](compiler-region-experiment.md) records its own bounded evidence and limits separately.
