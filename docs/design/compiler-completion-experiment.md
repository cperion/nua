# Boundary-owned completion: executable storage experiment

This tests step A of the [completion proposal](compiler-completion.md#8-the-next-probe-sequence).
It is **design evidence, not replacement-compiler implementation or ABI approval**.
The [activities experiment](compiler-activities-experiment.md) retains the earlier
failure and its raw evidence. That original allocation/control requirement now
passes through a storage transformation, rather than being rewritten away.

## Run and observed results

From Nua's root, using the current neighboring Mua checkout (not the dependency pin):

```sh
mkdir -p build/compiler-completion-probe
.local/bin/luajit ../mua/mua.lua docs/design/compiler-completion-probe.mua
.local/bin/luajit ../mua/mua.lua docs/design/compiler-activities-probe.mua
.local/bin/luajit ../mua/mua.lua docs/design/compiler-activities-probe.mua --edge-reclamation
.local/bin/luajit ../mua/mua.lua fmt --check \
  docs/design/compiler-activities-probe.mua \
  docs/design/compiler-completion-probe.mua \
  docs/design/compiler-completion-words.nua
```

Final focused checks passed:

- Completion probe: **exit 0; 6 witnesses, 36 prefix/branch checks, 13 expected
  invalid-plan/output rejections, 2 known Nua checks**.
- Original acceptance command: **exit 0; 31 constructed cases and 31 expected
  rejections**, including both concrete branch outcomes through the storage ledger.
- Ordinary activities probe: **30 constructed cases and 31 expected rejections**.
  Its automatic scalar-exit completion is now an explicit *pending* obligation;
  this logical check alone does not certify physical reclamation.
- Formatter checks and `git diff --check`: **passed**.

No C or libgccjit backend compilation, native Nua execution, production compiler
change, dependency-pin move or broad acceptance campaign is part of this work.
Raw development logs are retained under `build/compiler-completion-probe/`; final
results are in `activities.log`, `run.log`, `edge-reclamation.log` and `format.log`.
The original failing log under
`build/compiler-activities-probe/owners/edge-reclamation.log` is untouched.

## What changed

The same checked program family now admits:

- `CompleteBoundary`: logically ended local holdings leave explicit pending
  reclamation at a scalar return or trap. This must immediately precede that exit.
- `StackTop`, `StackWrite`, and unsigned `Greater`: observations, writes and the
  comparison needed by the experimental Nua completion words.
- Native `U64` constants and `Unit`, plus a fixture effect describing unrelated
  live growth on an externally used role.
- Placement facts tying **each allocation**, its logical group, a reserved role
  and an ordinary immutable mark operand together.

The original branch-local fixture is shared unchanged as a staged closure. Its
`group` and allocation operations remain inside their original branches. The
old eager `release_all` test no longer decides which branch-local groups can
physically be reset: it records pending work, checked separately from realization.
Explicit `reclaim` fixtures still exercise the original logical release rules.

[The separate storage activity](compiler-completion-probe.mua) takes the logical
program and its receiving boundary (here, the definition's entry and scalar exits):

1. Verify the semantic graph and collect allocations, external-role effects and
   completion sites. No source closure is replayed.
2. Reserve a distinct role for each allocation, avoiding externally used roles.
   Fixture group identity does **not** determine physical position. A witness with
   two live candidates in one logical group receives two physical roles.
3. Evaluate captures at entry; leave allocation, initialization, transfers and
   observations on their original control paths.
4. Replace each pending completion with restoration of all reserved roles, after
   logical ending. Evaluate the Nua words and instantiate their blocks into the
   **same program IR**. There is no second source tree or storage-program IR.
5. Check graph identity/types/dominance, preservation of source instruction and
   terminator objects, capture/write counts and exact saved-mark operands. Run the
   separate storage ledger on the tested concrete paths.

The two mutually exclusive candidates deliberately retain two roles. Sharing a
role is an optimization needing another proof, not a prerequisite for this result.
The plan also keeps two positions when both candidates are allocated before the
branch. Reconsidering placement produces fresh output and leaves earlier output
unchanged; fixture-side invocation counters prove it does not rerun source.

## Actual hosted Nua work, with explicit limits

[The storage listing](compiler-completion-words.nua) is ordinary typed Nua:

```nua
local capture = do(access, role): U64 = access.top role
local restore = do(access, role, mark: U64): Unit
    if mark > access.top role then access.fail "data stack reset above its top" end
    access.store role mark
end
```

It is loaded through current Mua and `nua.front.host`. A small, invocation-owned
adapter connects that host's generated protocol to the activities probe's existing
handlers. Word requirements use the actual `nua.types.U64` and `Unit` identities;
known unsigned comparisons use LuaJIT `uint64_t` values, including adjacent values
at the maximum, not floating-point approximations. The same Nua body folds known
safe/failing checks and residualizes the unknown top check, branch, trap and write.
Unsupported host protocol operations fail explicitly. `nua.stage` is never loaded.

This is **not yet actual `lib/stacks.nua` execution**. `access` supplies primitive
logical-position reads/writes. The Nua word owns the reset-above-top check; there
is no opaque Lua/C reset algorithm behind it. The ledger models allocation as a
four-byte cell, not a collection-growth implementation. `BeginOwned` remains an
abstract allocation event; the result is not backend-ready IR.

The primitive model assumes that an unused role is valid to observe as zero, and
writing that unused zero does not claim it. Inspection of `lib/stacks.nua` supplies
an existing mechanism for this: `top` returns zero for an unclaimed index, and
`reset` returns without claiming when that index's requested top is zero. This
source correspondence is useful evidence, **not proof of a replacement platform
binding**. Real stack descriptors, capacity/reservation, owner headers and native
call-site transport still need integration.

The adapter is limited to this listing, not a general replacement host evaluator.
In particular, native returns inside nested hosted control need a further return
contract. Its captured current path is restored on callback failure; independent
helper invocations own independent handlers and output.

## Independent storage checks

The ledger executes storage events in the produced graph, not source. It maintains
its own stack tops, claimed states, protected intervals, current custody and borrow
observations. It does not use the evaluator's ownership-transfer/release predicates.
It checks exactly-once completion, interval protection and capture-before-allocation,
as well as equality with the saved mark. Prefixes of 0, 16 and 64 bytes exercise
empty positions and protected older storage without allocating native memory.

The six witnesses cover:

| Witness | Checked result |
|---|---|
| Original branch-local owners | Both choices; only selected allocation runs; unused role stays unclaimed |
| Two already-live candidates | Both allocated; independent positions survive selection and logical ending |
| One proposed group, two candidates | Physical roles derive from allocations rather than the fixture grouping |
| Trap after allocation | Actual obligations complete before the original trap |
| Early scalar return | Early and continuing exits each complete their own path |
| Unrelated older-owner growth | Fresh reservation avoids its role; its larger live interval survives |

The growth fixture deliberately uses the allocator's first candidate role name,
so avoidance is tested rather than merely asserted. A proposed assignment to that
role is rejected. Bypassing that plan check and running the resulting bad graph
makes the independent ledger reject **both outcomes** with:

```text
restore clips unrelated live growth
```

The source program remains accepted under the safe assignment. This is a rejected
placement plan, not a new source restriction or a valid program counted as a
negative test.

Other mutants omit or duplicate restoration, retain a live holding at restoration,
remove or displace captures, substitute a different mark, retain unresolved work,
or merge independently reserved positions. In particular, placing captures at the
join still passes ordinary SSA dominance: the captures dominate their uses, but
occur *after allocation*. The ledger rejects that distinct ordering error. Graph
validity is not storage readiness.

## What this settles—and does not

For these acyclic, scalar-exiting witnesses, boundary-owned captures allow branch
local allocation with unconditional completion and **no runtime cleanup-selection
tag**. An empty unselected role is not an owner. Logical ending still precedes
physical reclamation, and custody transfer does not make live bytes reclaimable.

The storage contribution is finite for this subset: with A allocation sites and C
completion sites, realization evaluates A captures and A×C restores. These helper
bodies introduce no allocations, completion obligations or cyclic control. The
helper-instantiation check rejects such new contributions rather than silently
publishing incomplete output. This is not a loop/recursive summary-convergence
argument.

Semantic lifetime verification runs before realization. Its path enumerator cannot
prove a residual reset-above-top fault branch infeasible, so realized graphs go
through graph checking and the independent storage ledger—not a weakened semantic
checker that pretends every top write discharges ownership. Bounded concrete checks
are not a general proof for arbitrary residual arithmetic or control.

**This experiment alone did not justify adopting or beginning the full replacement.** The user's architecture-first requirement, including IR/activity infrastructure, has since been met by approval of [affine regions, completion and native tasks](region-completion.md), not by treating these bounded results as a complete model. The subsequent
[native-boundary experiment](compiler-boundary-experiment.md) tests component
completion while a sibling survives, with explicit marks, mixed origins and a
retained prefix. The [join follow-up](compiler-join-experiment.md) closes its original
unequal-component join through an absence proof. The [regional follow-up](compiler-region-experiment.md)
closes exchanged fields and supplies bounded cyclic port-agreement evidence. General
owning temporaries, early inline owner returns, current-header mutation followed by
move, loop/cyclic lifetime and placement analysis, and foreign/task boundaries remain
outside this experiment's evidence. Whole-path ownership analysis and synthetic `Owned U32` do not become
the production model merely because these bounded storage experiments pass.
