# Completion boundaries: a design proposal after the ownership probes

**Historical experimental proposal, not the adopted allocator/ABI.** The subsequent [affine region/completion architecture](region-completion.md) has now been approved, including the native-task scheduling correction. It satisfies the architecture-first prerequisite; the experimental results below remain bounded evidence, not validation of that new implementation.

At this proposal's stage, the user asked to return to reflection and design before starting
the real replacement compiler. This note derives a candidate completion design
from the [experiment results](compiler-activities-experiment.md), within the
commitments of [compiler activities](compiler-activities.md) and
[checked storage](checked-storage.md). [Syntax](../syntax.md) still owns source and
ABI contracts. No new language exclusion, runtime ownership scheme or ABI change
is adopted here.

**Experimental update:** [step A now has executable evidence](compiler-completion-experiment.md).
The original branch-local requirement passes through derived per-allocation roles,
boundary captures and Nua completion words, with an independent interval ledger.
This closes that bounded witness, not the native/component/recursive contracts below.
The subsequent [native-boundary experiment](compiler-boundary-experiment.md) tests
component custody, swaps, mixed results and retained prefixes across explicit calls.
The [join experiment](compiler-join-experiment.md) closes its original
`--unequal-components` witness. The subsequent [regional experiment](compiler-region-experiment.md)
closes the exchanged-component witness using boundary-owned relations and tests
finite region-port agreement across cyclic native calls. These are bounded results;
no general boundary ABI follows yet.

The immediate question is not “what handler makes the failing probe pass?” It is:

> Who owns each outstanding reclamation obligation at a boundary, and which
> executable operands and proofs make completing that obligation safe?

## 1. Keep the evidence; do not promote the probe's shortcuts

The experiments support immutable observations, distinct mutable places, integrated
evaluation/residualization, explicit ownership transfers and preservation of
reference/ownership correlation. They do not establish a production storage model.

In particular:

- A fixture's `group` is a proposed reclamation grouping, **not source semantics**.
  The real storage activity must be allowed to choose and justify another grouping.
- An allocation, a current owning operand and a reclamation group are different.
  The probe's allocation-to-operand map is not yet a complete holding/lifetime model.
  A real owner place can change its length/capacity header without transferring
  ownership. A move must capture its **current** header and transfer the holding,
  not reuse the header observed when allocation began. Contents-loan invalidation
  follows the operation and storage guarantee, not mere header mutation.
- Enumerating whole paths demonstrated a necessary relationship; it did not select
  an analysis strategy for loops or recursion.
- Collecting every open group into `return_extents` checks that work was not lost.
  It does not establish which result component carries which obligation, or which
  native captures a caller needs. That global-list shortcut must not become the ABI.
- Refusing raw owner-typed `Store` caught an invalid copy in this probe. A real
  prepared program can store owner headers after the corresponding transfer has
  been established. Ordinary payload stores and permission to duplicate ownership
  must not be confused in either direction.
- Named local cleanup is not enough: owning expression temporaries, early returns,
  callbacks, suspension and discarded construction need explicit completion owners.

Consequently, extending the current 2,000-line experiment indefinitely would give
false confidence. The next probe should test a smaller, explicit storage-completion
contract over the existing program family, retaining the current failing witness.

## 2. The proposed separation

Keep three related descriptions, not three program IRs:

| Description | Establishes |
|---|---|
| Holding and loan facts | Logical ownership, valid observations, transfers, ending, origins and stable/shared-position guarantees |
| Storage requirements | Which positions must coexist or grow independently; which bytes must remain protected; which boundaries must receive results |
| Completion obligations | The captures and restoration work still owed, its responsible boundary, and the holdings that prohibit exercising it yet |

A conceptual completion obligation identifies:

```text
identity
capture boundary and ordered capture sites
storage roles and the saved marks needed to restore them
protected storage, including logically ended retained bytes
live holdings that still depend on that storage
responsible completion boundary
```

This is a compiler description. It does not imply a heap object, reference count,
runtime finalizer closure, or a universal context record. Its physical operands,
when required, are ordinary typed operands in the same program IR. Its restoration
work must be realized by Nua storage words through the same evaluator.

**One obligation has one completion authority on each feasible execution.** Several
holdings may prevent its exercise. A borrowed reference never acquires that
authority or extends a logically ended contents lifetime.

A move changes custody and, where necessary, the responsible boundary. It does not
necessarily change the storage position, duplicate an obligation or immediately
rewind anything. Ending a holding invalidates its affected loans independently of
when retained bytes are physically reclaimed.

## 3. Solve the branch-local failure by questioning the grouping first

The failing fixture has this shape:

```text
left:   begin group L; construct A; transfer A to result
right:  begin group R; construct B; transfer B to result
joined: use result; end result; complete result storage
```

The ownership probe's original helper tried to release L and R unconditionally even
though only one beginning occurred. The missing beginning is real in that chosen representation;
it is not proof that the language needs a runtime “which owner exists?” flag.

### 3.1 Candidate: a receiving boundary with valid captures on every edge

Reserve suitable fresh result storage roles for the control region. Capture their
marks at the receiving region's entry, before either arm allocates:

```text
entry:
    mark_L = capture top of reserved result role L
    mark_R = capture top of reserved result role R
    branch flag, left, right

left:
    A = begin initialized ownership in role L
    jump joined(A)  -- this edge transfers A's holding

right:
    B = begin initialized ownership in role R
    jump joined(B)  -- this edge transfers B's holding

joined(result):
    ... use result ...
    end holding result
    restore role L to mark_L
    restore role R to mark_R
```

The unselected role remains at its captured mark. Restoring it is harmless **under
the isolation conditions below**. Allocation, initialization and user effects stay
in their original arms. Capturing a position's mark is not creating an owner or
initializing its contents.

This version deliberately keeps two roles. Proving that mutually exclusive result
allocations can share one compatible role is a subsequent storage optimization,
not a prerequisite for correctness. Conversely, A and B constructed *before* the
branch and growing while both live still require distinct compatible positions.
One completion region may cover several positions; a common region does not mean
a common growing stack position.

No new runtime cleanup tag is required for this witness. The source condition may
still choose the returned payload, but the completion boundary already has valid
marks for all of its reserved result roles.

### 3.2 The isolation proof is essential

The rewrite is admissible only if:

1. Each capture dominates every use of that mark, on every relevant continuation.
   Its position is already valid to observe: a purported capture must not secretly
   hoist allocation, initialization or a possibly trapping platform operation.
2. The roles are reserved for this result region during the covered interval, or
   equivalent noninterference has been proved.
3. Restoring a mark cannot undo growth or reclaim storage belonging to an unrelated
   surviving holding. An older owner's growth on the same position is not safe
   merely because the mark was captured earlier.
4. No surviving holding depends on bytes that restoration would reclaim. Moving
   custody elsewhere does not meet this condition: if the same bytes survive, the
   obligation follows them and the old boundary must not restore underneath them.
5. Capture, payload evaluation, ownership transfer, checks and cleanup retain their
   required order; trap and early-return paths complete their actual obligations.

Moving a capture to an arbitrary dominator is **not** a general solution. In
particular, an argument's existing contents and prior reclamation extent cannot be
replaced with a fresh mark taken at the call site.

The next experiment must transform the original allocation/control requirements
into this owned output and check these conditions. Merely hand-rewriting the
fixture to begin both groups outside the branch would not test the transformation.
A counterexample involving unrelated growth must reject the proposed plan without
turning the underlying valid source program into a language error.

## 4. Partial moves: partition first; otherwise retain under a real custodian

The pair-field experiment chose one group for two fields. That grouping is not
necessarily forced by any physical layout. Before inventing a shared cleanup
protocol, ask whether the obligation can be partitioned by independently movable
owner positions and their captures.

**Preferred candidate:** independently transferable components receive independently
transferable completion descriptions wherever physical non-overlap permits it.
Native type positions provide useful structure, but are not by themselves a proof
that historical retained extents partition cleanly.

For a pair whose two fields own disjoint regions:

```text
pair.left  carries the left region's obligation
pair.right carries the right region's obligation
```

Swapping the fields must select their completion operands together with their
headers. A field name does not determine which allocation or saved mark it holds.
Ending the left field cannot exercise the right field's obligation.

**If an extent genuinely cannot be partitioned**, retain one completion authority
at a boundary whose lifetime contains every remaining protector. Moving a field
updates that relationship; it does not copy the finalizer into both fields or
attach the entire extent to whichever field moves first. When a protector escapes,
the receiving boundary must adopt the necessary responsibility. Retaining control
responsibility is not heap promotion, and does not silently relocate the contents.

This requires a component-relative boundary contract. If a callee consumes one
field while its sibling remains in the caller, the callee may end the field's
holding but must not rewind the shared extent. The caller can remain the completion
custodian. If the whole result leaves, the result contract must transport that
responsibility beyond the returning frame.

We have **not proved** a finite, realizable arrangement for every such escape or
recursive combination. “Keep it in the enclosing scope” is insufficient when that
scope ends before a moved result. An unsolved grouping must be reconsidered; it
must not justify a new source restriction, hidden copy, or reference counting.

## 5. Mixed argument/fresh results keep the original argument obligation

An owned argument brings an existing holding and completion contract. A fresh
result region brings newly captured marks. They are not interchangeable because
their headers have the same native type.

For the case where the owned argument is consumed on every continuing path:

```text
entry: receive argument holding and its existing completion description
       capture the reserved fresh-result roles

argument edge: return the argument holding; logically end fresh scratch
fresh edge:    logically end the argument; return the fresh holding
```

One candidate normalization is to retain both sets of outstanding completion work
under the receiving result boundary. The selected header changes; the boundary
still knows about the argument's inherited obligation and the fresh region's marks.
Unused work may be discharged earlier where that is safe. Retaining it must not
restore the argument to a *new* mark or forget bytes outside its current header.

This normalization is justified only if the responsibility really transfers on
all relevant edges and the protected extents admit that custodian. A shared extent
with a surviving caller-side sibling needs the arrangement of §4. A `Ref` argument
with conditional move/borrow effects must keep those exact effects; it is not
silently consumed merely to make a cleanup envelope uniform.

The boundary contract must therefore describe result components and their
relationships, not just `result owns allocations {A, B}`. It needs the applicable
argument/fresh origins, transferred responsibility, remaining protection and
required native capture operands. The ABI arrangement for those operands is still
a proposal to test, not a change to the current ABI.

## 6. Preserve correlation with boundary-relative contracts, not whole worlds

The path enumeration proved that independent may-origin and may-end sets are too
weak. It did not prove that the compiler needs a list of every execution history.

At a join, a useful candidate contract is:

```text
joined(result, view):
    result carries holding H
    view borrows contents of H
    H carries the incoming allocation's storage guarantee and completion relation

left edge:  H receives A's holding; view receives A's contents reference
right edge: H receives B's holding; view receives B's contents reference
```

`H` is a boundary-relative holding identity, not a newly allocated object and not
an assertion that A and B are the same allocation. The incoming allocation/loan
origins remain inspectable. The post-join relationship can be stated once: the
selected view depends on the selected live holding.

Where an origin cannot be reduced to such a relation, retain an alternative keyed
to the actual join and its predecessor edges. Related facts must use the **same
selection identity**. Factor unrelated selections; do not eagerly form their
Cartesian product. A shared expression graph can express the relationship without
being another program IR. Its normalization and size behavior still need probing.

The checker must distinguish:

- a reference to whichever holding became `result`;
- a reference fixed to A even on an edge that ended A;
- a reference to an owner header versus a reference to its contents;
- a lifetime bound versus an exact target or physical allocation identity.

The second case remains invalid. Joining must not upgrade a potentially relocating
shared-position target to stable storage. Nor may it degrade a target proved stable
merely because the original place object disappeared. Storing, loading, matching,
returning and passing a reference must preserve the appropriate relation; unknown
mutation may invalidate an observation, never silently validate it.

“All possible origins remain live” is checked against feasible alternatives. It
does not mean combining the ending from one mutually exclusive edge with the
reference selected on another. This does not introduce exclusive borrowing or
retarget an old reference to a moved source header.

## 7. Native boundaries, loops and recursion must use the same contract

### Native calls and returns

A native definition describes requirements and effects relative to parameters,
result components and finite storage roles, not caller-local places or absolute
stack indices. Its caller captures required marks at the call's actual site, after
the relevant operand evaluation and before the callee can alter the covered storage.
The ordered capture site can be recorded before the final role count is known;
storage realization fills its required operands without replaying source. That
capture remains distinct from any physical grouping normalization justified earlier
in the caller.

An inline return supplies a continuation under the same ownership rules. A shared
return supplies a native boundary contract. Neither may leave its completion
authority in the callee's temporary builder or returning native frame. An owning
result's borrowed views are not permission to return arbitrary local borrows.

### Loop headers

Use the header as a boundary with a reusable contract. Check entry and continuing
edges against it after capturing their simultaneous inputs. Reconsider the owned
body when a continuing edge invalidates an assumption; exit-only changes affect
exit contracts, not automatically the next round. Preserve accepted known prefixes
and the source-visible identity of carried places, including alias writes.

A carried owner and its view can satisfy the same relationship on every iteration
without enumerating all earlier iterations. Replacing the owner while carrying its
old contents view must fail that relationship. A repeated allocation *site* must
not revive an older loan: abstract fresh instances and their carried relationships
are different from the instruction's identity.

For cleanup, distinguish a round-local region from storage carried to the next
round or returned from the loop. Reusing a static role does not license restoring
a mark that still protects carried contents.

### Recursive agreement

Recursive summaries must be boundary-relative equations over the group's finite
roles and owner/borrow relationships. Dynamic recursion depth must not create a
new static role, specialization key or summary identity per frame.

Forwarding a deeper result transfers completion responsibility; intermediate
returns must not restore underneath it. When a proved enclosing region covers
nested completion extents on the same roles, it can absorb those obligations and
keep the appropriate outer marks. This is a containment proof, not “pick the
smallest numeric offset.”

Combining two recursive results requires two compatible simultaneously live
positions before constructing the later result. Logically consumed bytes below
that result may remain in its result region. Independently movable result fields
must still meet §4; recursion cannot hide an unpartitionable extent or an unbounded
chain of runtime finalizers behind the return type.

No convergence claim follows merely from using a worklist. The probe must state
the finite vocabulary of roles/relations, how assumptions change, and why repeated
summary agreement and Nua storage realization cannot keep introducing new work
without closing it. That is separate from termination of arbitrary host Lua or
intentional source-level compile-time computation.

## 8. The next probe sequence

These are coherent experiments, not a new compiler feature inventory or a request
to migrate one helper at a time.

### A. Executable completion for the original failing branch

**Now tested for the bounded acyclic subset:** see the [completion experiment](compiler-completion-experiment.md)
for the six witnesses, invalid plans, actual hosted Nua listing and remaining platform
integration limits. The requirements that guided that experiment follow.

Give the storage activity logical allocation/control requirements and a receiving
boundary. Have it produce justified capture sites, role assignments and completion
work over the same IR, rather than requiring the fixture to preselect groups.

Exercise both branch outcomes, then two live candidates, an empty unselected role,
an early return and a trap. Add a negative *plan* that captures above an older live
owner and would undo its intervening growth. The source may be valid while that
particular plan is not: reconsider the placement, not the language contract.

Print the semantic program, its requirements, the chosen captures/assignments,
and the realized program. Check abstract stack tops and protected intervals with
a small independent storage ledger, separate from the evaluator's bookkeeping.
This is an oracle for storage events, not another implementation of source
symbolic execution. Realize at least the selected capture/release work through
ordinary Nua storage words, exposing any missing general primitive rather than
putting an algorithm in Lua or C.

**Success:** the retained `--edge-reclamation` requirement passes through an actual
storage transformation, and the interfering-growth plan is refused for a concrete
ordering reason. No conditional-group fallback or edited-away witness.

### B. Component completion across real boundaries

**Partly tested:** the [boundary probe](compiler-boundary-experiment.md) now preserves
one field's completion across explicit residual calls while its sibling remains
live, including mixed results and retained-prefix forwarding. The [join follow-up](compiler-join-experiment.md)
closes the original unequal-width case by proving an additional role absent on the
other path, including nesting and early scalar exits. This is graph/ledger evidence,
not C ABI realization. The [regional follow-up](compiler-region-experiment.md)
now closes exchanged components without padding and tests self/mutual forwarding
and replacement over fixed recursive ports. General normalization, recursive
combination and full source-level cyclic analysis remain open.

Extend that construction to independently moved fields, swapped field origins,
an actual shared definition returning argument-or-fresh storage, and recursive
forwarding/combination. Check captures at their call sites, retained prefixes,
non-overlapping growth, exactly-once completion and obligations owned outside
returning frames. Include an owning temporary and an early inline return.

The hard witness is not “two fields can be ended.” It is “a field can leave through
a native boundary while its sibling remains, without duplicating, losing or
prematurely exercising a shared obligation.” Test either a justified partition or
an explicit receiving custodian, with its native operands visible.

### C. Reusable agreement rather than path enumeration

Replace whole-path alternatives with the candidate join/header contracts. Compare
supported small acyclic cases with independent conditions against the current
exhaustive probe as a bounded oracle, including deliberately mismatched
owner/reference selections. That probe does not solve arbitrary path feasibility;
its enumeration is not an oracle for correlations between repeated conditions.
Then check loop backedges, zero-round exits, alias-written carried places,
replacement of a carried owner, nested exits and recursive summary changes.

The driver must demonstrate ownership of reconsidered facts/output, retention of
accepted prefixes, and no contributions left by rejected work. Numeric placement
changes alone must not replay arbitrary source computation. The existing targeted
retry transport is not replaced merely to run this experiment.

## 9. Confidence to start the real implementation

**The replacement must not begin before a coherent ownership/storage/completion
architecture is settled.** This includes its IR/activity infrastructure: the user's
subsequent correction withdrew the earlier readiness claim. The current Mua guide
supports the hosting and activity-owned vocabulary direction, but does not settle
Nua's completion contracts. Bounded probe success or an analysis that leaves valid
required programs unsupported is not the requested architectural endpoint. This
requires a complete model, not finished optimizers, libraries or broad backend tests.

**Current decision:** the user has approved [affine regions, completion and native task execution](region-completion.md). That complete operational model replaces the bounded placement premise and meets this architectural prerequisite. The criteria and next experiments below record the earlier proposal, not a demand to rediscover its fixed-pool solution or a claim that the new implementation is tested.

The following remain experimental evidence requirements, not sufficient permission
to start the replacement:

1. **The current valid-program failure is closed**, with captures and cleanup
   realized rather than a verifier accepting another unresolved logical operation.
2. **Ownership survives the hard boundaries:** partial field moves, mixed origins,
   recursive results, early exits and temporary cleanup have concrete successful
   traces and meaningful negative tests. No path relies on a returning builder or
   accidental whole-function retention.
3. **Cyclic agreement has a stated finite argument** for the probed residual
   shapes, including storage helpers' contributions. No iteration cap publishes
   unresolved semantics, and no unbounded whole-path enumeration is the design.
4. **One thin hosted-source integration works:** Mua's AST/hosted word machinery,
   actual native type semantics, the one evaluator, and Nua storage words connect
   without a second source AST or an old-evaluator fallback. Include owner-header
   mutation and a subsequent move, not only fixed initialized storage. Opaque
   fixture closures and synthetic `Owned U32` alone cannot establish this.
5. **Boundary checks challenge the abstraction:** at least focused traces for a
   materialized reference result, a foreign address exposure, and a task capture/
   suspension show that origins, observations and completion owners survive the
   boundary. This is not a requirement to finish every library or scheduler first.
6. **Readiness is independently checkable:** earlier inspected output remains
   unchanged, required checks/effects remain, all executable obligations are
   resolved, and the storage ledger detects unsafe captures, early rewinds and
   duplicated ownership. A shared mistaken predicate is not the only oracle.

These experiments were not by themselves sufficient to select a complete architecture. The subsequent approval resolves the region, custody, recovery and suspension mechanisms without requiring finished optimizers or broad library coverage first. Their implementation still needs independent checks; a hidden algorithm outside Nua or unresolved semantic obligation cannot be published as backend-ready merely because C/JIT agree. Compile-heavy validation remains separately authorized.

This proposal began as documentation-only reflection. The separate completion
experiment now tests **boundary-owned capture/completion with reserved result roles**,
without designing runtime cleanup tags around the fixture's chosen groups. No
production compiler implementation or ABI change follows from that result. The
original unequal-component join is now closed by the [absence-normalization probe](compiler-join-experiment.md).
The [regional experiment](compiler-region-experiment.md) now preserves that field
correlation without equal native vectors, and gives a finite argument for role-support
agreement over a sealed cyclic call graph. It does not settle general cyclic lifetime
agreement or placement. Those architectural questions subsequently led to the approved independent-region model, not another incoming-width variant. Its complete mechanisms and outstanding implementation checks are recorded separately in [region completion](region-completion.md).
