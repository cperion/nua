# Evaluation, control regions and ownership: executable design experiments

This is evidence for [the compiler-activities design](compiler-activities.md), not
an implementation-completion claim. The [probe](compiler-activities-probe.mua)
constructs and checks a small part of the proposed representation. It neither
changes Nua's compiler nor supplies a fallback for a replacement path.

The method follows the current local Mua compiler guide, including stateful
vocabulary factories (§4.6). Helpers are curried, including delayed branch bodies;
family handlers retain Mua's fixed `node, recurse, ...` calling convention.

## Running it

From Nua's root, with the neighboring Mua checkout:

```sh
mkdir -p build/compiler-activities-probe
.local/bin/luajit ../mua/mua.lua docs/design/compiler-activities-probe.mua \
  > build/compiler-activities-probe/run.log 2>&1
.local/bin/luajit ../mua/mua.lua fmt --check docs/design/compiler-activities-probe.mua
```

The Mua checkout used for this experiment is `b93e36fa75c9d23cc1e68c70bdb5834e8c17b476`.
This does not move `tools/mua.lock`. Contracts remain enabled. Generated output and
raw development logs stay under ignored `build/compiler-activities-probe/`.

**First experiment:** 18 constructed cases and 18 expected rejections passed.
**After the ownership extension below:** 30 constructed cases and 31 expected
rejections passed. At that milestone the separate `--edge-reclamation` acceptance
witness exited 1: one valid ownership scenario could not be completed. It was not
counted as an expected rejection or a skip.

**After the [completion experiment](compiler-completion-experiment.md):** that same
requirement passes through derived captures and Nua completion work, checked by a
separate storage ledger. The ordinary probe's automatic scalar-exit completion is
now explicit pending work, not a claim of physical readiness. The historical failure
and logs below remain evidence. No C/JIT compilation, native execution or broad
acceptance suite was run.

## The construction

Fixtures supply opaque, curried closures directly at the staged-operation
boundary. One invocation of `construct` owns fresh identities, blocks, places,
reference facts and its evaluation vocabulary. The same arithmetic, read, write
and conditional handlers handle known and residual inputs. There is no preliminary
interpretation followed by another traversal to emit the program.

The checked data distinguishes:

- **operands:** typed constants, definition parameters, block arguments and
  instruction results;
- **places:** identities distinct from their evolving contents and physical memory;
- **staged values:** scalar operands, or reference operands with origin descriptors;
- **contents facts:** uninitialized, tracked value, or an ordered memory observation
  required on the next read;
- **program output:** a definition with blocks, instructions, terminators, places
  and explicit reference/return contracts.

Private blocks may be open. Publication constructs closed checked blocks and runs
a separate graph verifier. The verifier does not execute fixture closures or
implement native evaluation again: it checks identity, types, edges, dominance,
definite memory initialization and the reference obligations represented here.
Both the activity's evolving facts and its resulting definition are printed.

## What the traces established

### 1. Contents merging does not imply memory

The same snapshot fixture returns known `3` and `4` for known conditions. With a
runtime condition, its differing contents become one block argument:

```text
left:             jump joined(2)
right:            jump joined(3)
joined(current):  answer = add 1, current
                  return answer
```

No stores or loads are needed. The earlier observation remains `1`. Nested
conditionals use the same region constructor and pass their actual continuing
blocks to the enclosing join.

### 2. Address exposure creates an edge obligation

When only one branch exposes the place, that branch first establishes its current
contents in memory. The other branch must establish *its* contents before reaching
the shared continuation. The joined read is then an ordered load.

This is not a rule that every differing value goes into memory. It is a consequence
of one predecessor requiring a memory-backed place. The separate materialized
snapshot case also verifies that a read before a later store names its own load
result, not a recipe for re-reading the place.

`Expose` is an abstract synchronous external observer/mutator of an initialized
`U32` place. It is not a foreign ABI implementation. A known return value following
it does not erase the exposure.

### 3. Only continuing predecessors contribute continuation facts

An uninitialized place on one live predecessor makes a subsequent read invalid.
The same uninitialized fact on a trapping predecessor does not contaminate the
surviving continuation. Two trapping arms produce no join and no fabricated return.
Ending a reference origin on a trapping arm likewise does not end it on the other
arm's continuation.

### 4. Pointer identity is not its reference contract

Selecting between two reference parameters produces a pointer block argument and
an explicit union of origins. One origin is stable and the other shared-position;
both descriptors survive the join and the returned-reference contract. Ending
either possible origin makes a subsequent use invalid. Known selection does not
acquire the unselected origin.

The verifier rejects deliberately deleting the shared-position origin, even when
the return contract is also changed to conceal that deletion. It compares the
join's descriptor with its incoming operands' descriptors.

This tests **preservation**, not discovery: the fixture supplies incoming reference
contracts. It does not establish how a real word derives them or how growth acts on
the corresponding storage.

### 5. Compiler-generated transport is not a new source borrow use

The first verifier incorrectly checked borrow liveness at every operand use,
including jump arguments. The `unused-ended-reference` fixture exposed the error:
a reference that is never used again may become invalid, but its unoptimized
pointer operand still travels through a generated join.

The corrected checker separates operand availability from permission to observe a
borrow. Evaluation checks source-level reads and assignments; the graph verifier
also checks residual stores and returns. An edge must supply defined, correctly
typed operands and preserve provenance, but does not invent a source observation.
Returning the invalid reference still fails.

The original failure is retained in `build/compiler-activities-probe/06-unused-borrow.log`.
This distinction does **not** permit moving ownership headers across invalidating
cleanup, losing capture obligations, or using a stale reference in source code.
Those are separate obligations, not consequences of pointer-bit transport.

### 6. Activity ownership needs completion on rejection too

Independent and nested constructions preserve earlier inspected output. Repeating
a fixture produces the same printed representation with fresh construction data.
Paths and place identities from another activity are rejected, even when their
local numeric name supplies would collide.

Retained handlers reject mutation after successful publication **and after rejected
construction**. The owning activity closes them through protected completion; this
is not a general transaction framework and does not roll back arbitrary Lua effects.

## Boundary of the first experiment

This probe starts at the hosted-operation boundary, not at parsed Nua source. It
constructs one definition, not a module registry or the complete word/application
model. It covers `U32` addition, booleans, local places, acyclic regions and
externally supplied `Ref U32` contracts. It assumes immutable published descriptors;
it does not freeze arbitrary Lua tables.

At that first step the probe did **not** implement owner creation or transfer,
partial moves, loops, recursive agreement, shared `call` specializations, aggregate
component knowledge, reference loads from memory, storage assignment, Nua storage
realization, tasks or a backend. `EndContents` was a logical lifetime event, not a
container algorithm. The graph checker explicitly rejected cycles rather than
claiming a cyclic proof. These were experiment boundaries, not Nua language
exclusions or a scalar-only replacement milestone.

The next experiment carried an owner and a reference together, made transfers and
cleanup explicit, and challenged independently moved fields and an inline return.
Its results follow; the output is still not claimed backend-ready.

## Second experiment: ownership, edge correlation and reclamation

The extension uses the **same instruction, operand and control-flow families** and
the same evaluation activity. It adds a synthetic `Owned U32` probe type denoting
one initialized logical allocation, not a proposed Nua surface type or a container
implementation. Even known initialization produces required storage work.

Three identities must not be conflated:

1. **Allocation identity:** which storage and contents lifetime a value describes.
2. **Current owning operand:** which value presently carries the right to transfer
   or end that allocation. Copying the operand's immutable identifier does not
   duplicate that right.
3. **Reclamation group:** which allocations a candidate release would reclaim.
   Ending one member does not license releasing the group.

The probe maps each allocation to its current owning operand on each path. This
is an experiment with custody, not the final representation of holdings and
lifetimes. Reclamation groups are explicit **proof inputs**: no physical stack,
watermark, capacity, growth ordering or contiguity is inferred from their names.
The fixture's `group` and `reclaim` operations propose compiler storage obligations;
they are not a public API that Nua container authors would have to use.

### One operation system, inspectable obligations

The new checked instructions describe beginning a group, beginning initialized
owned storage, transferring an owning operand, obtaining/observing a contents
borrow, logically ending a holding, and releasing a reclamation group.

Handlers both update facts and produce these instructions. Ordinary writes of
owning values transfer them; overwriting a live owner captures the supplied owner
before ending the overwritten one. Reading an owner through the scalar-value
interface is refused. An inline invocation uses the caller's evaluation activity,
captures its returned owner and ends remaining local holdings without constructing
a native call or a second allocation world.

Owner block arguments consume their incoming ownership. Edge inputs are captured
before changing any destination custody, so two independently owned fields can
swap. Supplying the same holding twice on one edge is rejected even if its header
is an immutable operand and both target arguments have the right type.

### The crucial join needs correlation

The two-candidate fixture constructs A and B before the condition. On one edge it
borrows A's contents, moves A to the result and ends B. On the other it borrows B,
moves B to the result and ends A. Both the owner and reference join through block
arguments; observing the selected reference is valid on either incoming path.

A flattened union says that A **may** have ended and B **may** have ended, while
the reference **may** borrow either. It therefore rejects a valid observation.
The fixture explicitly demonstrates that both origins appear in that flattened
ending set while the path-sensitive proof succeeds.

Evaluation now preserves ownership alternatives at the join, and verification
walks the acyclic graph's alternatives without executing source closures. Each
alternative retains the selected allocation, its current custody and its reference
origins together. Earlier scalar/reference fixtures continue to pass. The old
flat ending maps were removed rather than retained as another competing answer.

**This is not the chosen scalable analysis.** Enumerating acyclic paths can grow
exponentially; the experiment establishes the correlation that an eventual compact
representation must preserve. It supplies no loop or recursive convergence proof.
The verifier and evaluator share small ownership-contract predicates, so passing
both is not an independent semantic oracle; explicit expected traces and malformed
graphs test the obligations too.

### What the ownership cases established

- Known true and false selection keep both allocations made before the condition,
  but transfer the appropriate candidate. A known condition does not erase earlier
  storage effects.
- A selected owner can return inline, be placed in a caller local and lend a valid
  contents reference there. Child completion does not end the transferred holding.
- Independently moved field places can end separately. Ending the first does not
  invalidate the other, but releasing their shared reclamation group early fails.
  These are explicit member places, not an implementation of aggregate layout.
- A returned header can describe only the later live allocation while its cleanup
  contract still includes a group containing a logically ended prefix. Removing
  that larger obligation from the published definition fails verification.
- Mixed argument/fresh results retain the existing argument allocation on one edge
  and the fresh allocation on the other. Their return contract includes the
  unreclaimed work from both alternatives. The input is a native owned argument,
  not a foreign/export ABI accepting owners.
- A move on only one edge ends the unmoved owner on the other. A trapping path also
  ends its local holdings and records its reclamation obligation; the later storage
  experiment realizes that obligation before the trap.
- Retaining physical bytes does not keep a borrow valid after logical ending.
  Replacement invalidates the old contents borrow. A local contents borrow cannot
  escape an inline invocation whose completion ends its owner.
- Deliberately moving cleanup before result capture, duplicating an owning edge
  input, releasing under a live field, releasing twice, or omitting a returned
  reclamation obligation is rejected.

A malformed raw `Store` of an owning operand exposed another real checker gap:
ordinary store type checking accepted a header copy without transferring custody.
The probe now refuses owner-typed `Store`; its owner writes require explicit
transfer operations. This is a restriction on this experiment's instruction
contract, not a claim that a backend never stores owner headers. The original
unexpected acceptance is retained in `owners/09-raw-owner-store.log` under the
experiment's build directory.

The negative cases include **malformed IR and incomplete internal constructions**,
not only invalid source behavior. In particular, deliberately abandoning a moved
owning temporary demonstrates missing cleanup work; it does not establish a Nua
rule forbidding unused owner-valued expressions. General temporary lifetime
completion is not implemented by this fixture interface.

### The original valid-program failure: branch-local reclamation groups

The ownership milestone left this acceptance witness unmet. It now also runs the
separate completion activity; keep new output separate from the historical log:

```sh
mkdir -p build/compiler-completion-probe
.local/bin/luajit ../mua/mua.lua docs/design/compiler-activities-probe.mua \
  --edge-reclamation > build/compiler-completion-probe/edge-reclamation.log 2>&1
```

Each arm creates its own group and owner, then moves that owner into the common
result. The joined borrow is valid, and logical ending of the result is valid.
However, the group's entry event occurred on only one path. The original completion
helper could not emit an unconditional release of both groups:

```text
probe needs edge-specific reclamation for this group
```

**Observed at the ownership milestone: exit 1, one unmet valid-program requirement.**
The witness stayed executable, not rewritten to reject the source program, disabled,
or given an old-evaluator fallback. The ordinary passing probe did not claim that
this separate acceptance witness passed. The later completion experiment closes
this requirement while preserving its original branch-local allocation/control body.

This exposed the next representation question: ownership alternatives prove what
must happen, but are not themselves executable cleanup. Region captures and their
cleanup obligations need an explicit edge/boundary contract that storage realization
can implement. We have not chosen a runtime token layout, a conditional-release
scheme or a general region algorithm from this example. No runtime reference
counting or new source-level drop flags were introduced.

Raw development evidence, including the failing witness, is under
`build/compiler-activities-probe/owners/`. The first ownership run also exposed
LuaJIT's 60-upvalue limit in this deliberately single-file experiment. A named
vocabulary now groups the ownership constructors and contract helpers; it carries
no compilation state. The newer helpers and all delayed bodies remain curried.

### What remains unproved

Neither reclamation-group membership nor successful logical checking proves a
physical Goose layout. Stack marks, distinct concurrent growth positions, recursive
result regions and independent-field extent partitioning remain unresolved. The
later completion experiment establishes a bounded capture/reset realization through
Nua words, not a complete physical storage implementation. Native owner-result ABI realization, early inline exits,
reference loads from memory, arbitrary aggregate layouts, tasks and backends are
also outside this experiment. Loops remain explicitly unsupported by the probe,
not excluded from Nua.

The subsequent completion experiment closes the branch-local-group witness through
explicit boundary captures and completion work. The [native-boundary follow-up](compiler-boundary-experiment.md)
now tests a field crossing explicit calls while its sibling survives. The [join follow-up](compiler-join-experiment.md)
closes its original unequal-width failure. The [regional follow-up](compiler-region-experiment.md)
now closes the separate exchanged-component acceptance with boundary-owned relations
and tests finite port agreement across cyclic native calls. General native/recursive
completion and real hosted owner-header integration are still not established.

Subsequent [design reflection](compiler-completion.md) questions the fixture's
branch-local grouping before choosing a runtime cleanup carrier. It proposes
boundary-owned captures of reserved result roles, with explicit noninterference
proofs, and works through partial moves, mixed origins and the confidence gates
for real implementation. The [completion experiment](compiler-completion-experiment.md)
now tests its first step; the field/native/recursive contracts remain proposals.
