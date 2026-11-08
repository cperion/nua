# Deriving storage from invariants

**Revision 4 derivation, with revision 5 decision updates.** The user has now
approved the overall [checked-storage design](../checked-storage.md), including
safe typed-buffer composition, late physical placement and cross-position result
relocation. The detailed symbolic records below remain design candidates, not an
engine selected merely by this document. The earlier Goose investigation did not
itself approve those choices; the withdrawn scalar M1 remains withdrawn.
This develops [derivation §4](derivation.md#4-third-problem-return-ownership-not-just-bits).

[Syntax](../../syntax.md) §§9.2–9.13 owns Nua's language rules;
[architecture](../../architecture.md) §§7–8 describes current implementation.
[Memory design](../memory.md) §§5, 9–10 and decisions D5–D13 supply rationale,
but some old status labels are stale. Source reading and the staging observations
in §8 are distinguished from the proposed replacement below.

Goose was read at `7b90f91d91845f4ef1712e16ed053f395e4e6e1c`: [specification][goose]
§§1, 3.4, 4–5, 7.3–7.4, 7.8–7.9, 9–10 and Appendix C/E, plus the relevant
[implementation notes][goose-impl], especially §§6.2–6.5. These are reference
material, not Nua authorities. The method is the Mua guides' explicit state,
activity completion and boundary reasoning, not Goose's C++ organization.

## 1. What Goose establishes, and what Nua changes

Goose's key distinction is **variable size, fixed after construction** versus
**resizable throughout life**. Packed nested strings use the first; independently
growing nested owners would need a different arrangement. Its strong invariant
is one live resizable per stack, topmost for its entire life. Construction owns
its destination until complete; completed variable-size data may be buried.
Scope exit restores watermarks. Its implementation assigns stack indices during
code generation, after checking and optimization.

Nua retains nonmoving data stacks, scoped reclamation and destination-aware
results, but has deliberately changed other parts:

| Problem | Goose | Required Nua treatment |
|---|---|---|
| Independent resizables in aggregates | One ordinary resizable tail; root structs group separate components but cannot move/return as values | Multiple owner fields, movable aggregates, type-directed owner positions |
| Owners in container elements | Resizable elements forbidden; variable-size elements freeze after construction | Shared position arenas; growth may relocate contents and ends the affected borrows |
| Moving existing storage | General moves not supplied; return move has destination/copy rules | Transfers on assignment, arguments and returns; source becomes unusable, destination owes release |
| Two different returned locals | Destination placement cannot cover both; copies are permitted with warnings | Separate simultaneous candidate storage; no implicit copy for an ordinary one-tenant move |
| Recursion holding owners | Nonfixed locals/temporaries cannot span a cycle call | Frames share stack indices; prove growth and result/release ordering |
| Reused slots | Same-typed stale references can be allowed | Preserve Nua's borrow invalidation and generational `Id` contract |
| Reclamation | Scope watermarks | Scope releases plus exact replacement/partial-move cleanup; general last-use release remains later work |

Thus neither “copy Goose's restrictions” nor “all allocations are arbitrary
heap objects” follows. Derive Nua's additional proofs without losing the simple
stack mechanism. Do not import Goose's packed ABI, root-specialization keys,
whole-program checking of both constant branches, or guard-page policy either.

## 2. Invariants before records

These obligations come from Nua's existing contracts, not proposed new refusals:

1. **Place identity survives specialization.** A header's place, its contents'
   storage and a reference to that place are not interchangeable. Replacing a
   header's owner does not replace the place; it ends the old owner's lifetime.
2. **A holding has a responsible releaser on every reachable path.** A move
   transfers that duty, not just bits. A path that has moved a source cannot
   release it as though it still held the storage. Conversely, a move on another
   path cannot suppress this path's required release.
3. **Simultaneously live independent growing owners need noninterfering storage.**
   Sequential lifetimes can reuse indices. Shared positions and recursive frames
   are different, explicit arrangements, not exceptions silently ignored by an
   allocation counter.
4. **A reset cannot reclaim surviving data.** Preserve native top/base checks,
   capture the required watermark at the correct execution point, and distinguish
   ending a logical owner from reclaiming a larger result region. Shared-position
   dead bytes are not reclaimed by independently resetting each element.
5. **Borrow permission follows the lifetime and invalidation contract.** Whole
   owner, contents, element/position, iteration and lending-activity dependencies
   differ. A runtime-chosen target does not become an exact place merely because
   its lifetime is bounded. A constant pointer does not make a borrow immortal.
6. **Growth preserves or invalidates according to the semantic position.**
   One-tenant storage does not relocate; shared-position growth has the existing
   invalidation even when this particular execution fits its current capacity.
   Recursive growth additionally requires that no younger live region obstruct it.
7. **Only the surviving program needs storage.** A known-removed branch allocates
   nothing. Operations before a known choice do not disappear merely because one
   result is unused: checks and ordered effects still count. Owners remain native
   runtime storage; their element contents are not a new compile-time heap.
8. **Container algorithms remain Nua.** Initialization, growth, copying,
   compaction and release use ordinary words over the minimal storage/lifetime
   primitives. Neither symbolic placement nor preparation licenses opaque C/Lua
   versions of those algorithms.

The implementation may use several records or combine related facts. The
following distinctions must nevertheless be expressible:

| Distinction | What it answers |
|---|---|
| Header place | Where does a direct access or `Ref` point? |
| Owner lifetime / current holding | What currently occupies that place, and who owes its release? |
| Allocation occurrence and owner-position topology | Which storage is created here, and which independent stacks/arenas does its type need? |
| Receiving destination | Where must this result/header be established, with which placement requirements? |
| Borrow dependencies | Which owners, contents or activities must still be valid at a use? |
| Reclamation extent | Which regions and saved marks must eventually be restored, potentially beyond the selected owner's bytes? |

These are not six new public types or a universal heap model. For example, a
place may receive a new owner after a move; confusing place identity with one
allocation would revive old borrows or make legitimate reinitialization impossible.
An allocation occurrence in residual code also has multiple runtime instances
inside a loop/recursion. A source location alone identifies neither an unrolled
occurrence nor a particular runtime activation.

## 3. Work the two-live-owner example through completion

The [probe](storage-probe.lua) uses this source inside residual evaluation:

```text
local choose_owner = do(flag: Bool): Grow U32
    local left = Grow(U32) {}
    local right = Grow(U32) {}
    left:push 1
    right:push 2
    if flag then return left end
    return right
end
```

Name the created storage A and B, the source header places L and R, and the
receiving place D. These names describe this construction, not physical indices.
Before the conditional, L holds A and R holds B. They coexist. Their ordinary
Nua initialization and push operations retain their order and checks.

### Known control and inline return

With `flag = true`, only the left return is evaluated, but both earlier owner
constructions and pushes have already been staged. A transfers to D; B ends.
L is moved, not a second owner of A. D's continuation may use and grow A, subject
to the normal storage rules, and eventually releases it. There is no native
function for `choose_owner` merely because the inline invocation has ended.

### Dynamic control and inline return

| Return edge | Holding in D | Source no longer usable as owner | Other storage |
|---|---|---|---|
| True | A | L | B ends on this edge |
| False | B | R | A ends on this edge |

Each edge establishes its result and completion obligations **before** transfer
to the continuation. D exists on both paths, while its header identifies different
storage. Do not equate A and B, emit both releases unconditionally, or retain both
source holdings after the join. Result inputs must be captured before cleanup
that would invalidate them; exact relative ordering of independent cleanup is
not prescribed by this table.

This is ownership reconciliation, not scalar equality. A partial move followed
by a continuation using the old source remains an error under the existing rule;
no runtime drop flag or “maybe still owns” source operation is introduced.

### Explicit `call`

The callee has fresh parameter origins, not the caller's whole facts map.
For known `true`, only A is a possible returned allocation. For a dynamic flag,
both A and B are candidates. The completed call contract must describe:

- the candidate storage needed while the callee runs;
- the selected result header and transfer into D;
- which scratch storage the callee ends and which reclamation duty the caller
  receives;
- borrowed-result origins and move/retirement/growth effects on arguments.

One logical result does not imply one result stack. Numeric `local:0` and
`result:0` in the existing implementation are different base-relative namespaces;
their equal offsets do not identify storage. A caller reserves the result region
apart from its live owners and the callee's scratch.

For recursion, the returned header may name only the top part of a region that
also contains consumed results below it. Releasing only the selected header is
not a general substitute for the caller's saved-region rewind. Conversely,
rewinding an entire region at an inner return can destroy an outer result.
Forwarding an owner argument is another origin, not a fresh result allocation.
A complete protocol must account for those alternatives without silently copying
owners or taking ownership of a caller's mere `Ref`.

## 4. Candidate: describe allocations once, assign their stacks later

**Proposal, not a completed algorithm.** An owner creation produces a logical
allocation occurrence with its type's position topology. Initialization and uses
refer to its symbolic stack operands. A return records that the allocation can
flow to the result; a move changes its holder, not the allocation's identity.
Exits retain ordered release obligations. Function calls refer to the callee's
result requirement and their own receiving destination.

For the nonrecursive example above, this gives a small derivation:

1. Stage L/A and R/B once, recording that their lifetimes overlap.
2. Evaluate the known branch or both residual arms. Record A alone, or A and B,
   as result candidates, with each edge's transfer and cleanup.
3. Assign the candidate(s) distinct result slots; assign the remaining scratch
   outside the result region. A deterministic lowest-free policy can remain.
4. Resolve each symbolic stack operand consistently in initialization, later
   accesses and cleanup. Establish the caller's pre-call marks and the eventual
   result-region release at their original execution sites.

No source branch changes in these four steps. Discovering a second candidate
changes a storage assignment, not a fact on which evaluating that branch relied.
This is a candidate for removing the current result-placement rebuilds, rather
than a reason to design reliable allocation-ordinal matching first.

**Source support, not replacement proof:** `Mem.stack_index` already yields a
*dynamic* U64 expression (`stack_index` or `res_index`), not a known integer fed
to the library algorithms. Result-region offsets already resolve in preparation.
Extending that symbolic boundary is therefore concrete, but an audit still owes
all consumers, layout-dependent specialization and completion cases. Do not
replace useful known facts with runtime queries merely to make planning easy.

Physical numbering must not choose a different growth algorithm, alter source
order, create a new borrow permission, erase a check, or make an already read
header refer to another allocation. Those would require a separate semantic proof.
An escaped raw pointer likewise cannot be repaired by renumbering after it was
observed; its storage stability and lifetime remain obligations.

### A real completion problem: generating the release

Not every late decision is just an integer substitution. The current
`h.result_destination` builds one rewind action per reserved result stack, with
`S.stack_rewinder` capturing its top **before the call**. The region's width can
depend on completed recursive result requirements. Arena releases also restore
dead-byte bookkeeping (`stacks.close_arena`), not just a top.

A replacement that describes this symbolically must say how the eventual work
becomes ordinary Nua computation. A candidate is to retain an owned, typed
storage-completion description at the entry/exit site, then stage the necessary
Nua storage words when the finite region requirement is known. This is not
permission to rerun arbitrary user code, insert a new native boundary, or emit a
backend-private C cleanup algorithm. It must preserve dominance, execution count,
original-site captures and the already-checked lifetime effects.

**Still open:** the exact handoff for that staging, and whether it can introduce
new definition dependencies that require storage planning again. A runtime loop
over an unnecessarily unknown count is not an automatic acceptable workaround.
The scalar proposal's “all construction resolved before preparation” must be
refined: semantic completion can admit documented symbolic layout operands;
backend readiness cannot admit unresolved operations or lifetime obligations.

## 5. Nested destinations expose a separate contract question

Physical arena placement and shared-position semantics are **not the same fact**.
`Builder:open_tenant` / `adopt_tenant` can place a still-local owner at the top of
a holder's arena. While the holder leaves that arena untouched, the temporary
keeps its one-tenant growth/borrow guarantees. At handoff the element takes the
header; later operations through that element use shared-position semantics.

Consequently, changing an allocation's physical target need not change its
specialization mode. But proving the quiet interval is essential: intervening
holder growth, compaction, release, another tenant, or a call reaching the holder
can invalidate it. Borrow semantics cannot depend on whether this optimization
succeeded. Cross-position relocation remains Nua work. Under the subsequently
approved cost rule it is also permitted for immediately supplied call results; ordinary owner
moves/returns still cannot silently copy.

Now put the witness's result into an element:

```text
local groups = Grow(Grow U32) {}
groups:push (call choose_owner flag)
```

The callee's two live growing candidates cannot simply be identified with one
shared-position destination. The current source permits call-result tenant
placement only when the result-region width equals the returned owner's width
and the other safety conditions hold. The probe observes that condition failing
here. `put_owner` then takes its `copy_of` path, followed by ending the source.
This is source-path evidence of copying, not measured native execution.

For known `true`, the probe instead observes discovery of the tenant placement,
an enclosing rebuild, then successful adoption. The unselected B is still built
as independent scratch; only the returned A needs the destination's stack.

**Resolved in revision 5:** the user approved relaxing the universal element-result
no-copy promise. Syntax §9.2/§9.13 and memory design §5.3/§5.9 now distinguish an
ordinary no-copy owner return from a subsequent cross-position transfer, which
may relocate contents. A fresh element filled through a borrowed writer avoids
that transfer. Automatic placement is an optimization, not a correctness
requirement. The six observations below remain historical staging evidence.

This is not a proof that destination routing is impossible. In this particular
example the Bool is available before construction, so routing one candidate to
the destination and the other to scratch is an alternative to investigate. It
is not a general solution when the choice is computed from the owners *after*
they have grown, or when constructing a result can reach the receiving holder.
Moving that choice earlier would change evaluation. The reviewed choice is now
permitted cross-position relocation, not new program restrictions or a different
heap representation. Assigning one stack per runtime
element would not preserve the fixed stack-count model.

## 6. Borrowing, loops and recursion constrain the same description

**Earlier observations versus continuing loans.** `n = xs[0]` may need a captured
scalar before `xs:clear`. A view `s = xs:all` still depends on the contents after
its pointer/length are captured: `s[0]` after the clear remains invalid. The
snapshot proposal cannot fix a stale loan by moving its later use earlier.

A move of contents does not magically redirect a `Ref` to the old header, or
extend an invocation-local borrow past its permitted boundary. Distinguish old
header references from contents views and from independent scalar copies.
The current `move_owner` preserves aliases for later lifetime ending, while
`mark_moved` prevents source-place use; frame tokens have their own endings.
The replacement must trace those boundaries, not infer universal loan transfer
from the destination receiving the same bytes. This note establishes no new
acceptance rule for self-referential owner results or borrows crossing moves.

**Loops.** An owner created in a round must end or transfer before that round's
storage is reused. A carried header place keeps its identity; it need not keep
the same owner instance after replacement. Header agreement therefore includes
holdings and admissible borrow origins, not just numeric contents. Continuing
edges capture inputs and transfer holdings before cleanup, with simultaneous
assignment; exits establish their own continuation. An inner break is not an
outer back edge. The existing restrictions on changing scoped provenance remain;
there is no proposal to make an invalid loan merely dynamic.

An allocation site in a residual loop denotes one construction operation executed
many times. Known unrolling produces multiple occurrences. Reusing a physical
index across those instances needs an ending/transfer proof, not equality of
source locations. Accepted known prefixes keep their own occurrences when a
later round is reconsidered.

**Recursion.** A fixed number of stacks can hold nested activations, but an older
owner may grow only when no younger live region obstructs it. Result channels
must preserve activation order and transfer or retain consumed regions until the
proper outer rewind. A caller-reserved result region cannot be freshly reserved
at a higher stack index on every back edge. These are layout/ordering obligations
over surviving calls and growth sites, not blanket recursion rejection.

Recursive summaries can also affect *evaluation*: a newly discovered move-out
can invalidate use of the caller's source, and retirement can invalidate loans.
Those changes are not numeric placement changes. Either checking remains pending
under an explicit construction contract, or the dependent construction is
reconsidered. No pretend valid value under pending invalidity is proposed.
The current targeted transport has no demonstrated defect; this derivation does
not select a different driver or transport.

## 7. Who owns the description when evaluation is reconsidered?

| Boundary | Candidate disposition |
|---|---|
| Ordinary inline invocation | Operate on caller path facts; own its exits and lifetime completion, not a second native allocation world |
| Residual branch | Share identities; fork holdings/validity facts; retain edge-specific transfers and releases for reconciliation |
| Child accepted by parent | Adopt allocation occurrences, uses, release descriptions and graph evidence together with code |
| Parent rejected | Drop the child's accepted work too; restore the parent's entry facts and justified surviving edits |
| Accepted prefix, later rejected round | Keep prefix occurrences and obligations; discard only the rejected region |
| Materialized function completed | Publish a boundary-relative contract; no caller-local holdings or discarded call operands retained |
| Exact-view storage planning | Own assignments and proofs for that graph; changing roots, bodies or dependencies invalidates the affected plan |

Discarding construction does not run a native release. It removes a proposed
allocation and its uses/releases from the program. Compiler guards and genuine
host resources still need their own completion. A retained callee does not own
its rejected callers; G01's already-observed call-index edge remains relevant.

**Candidate simplification:** compute placement from live allocation occurrences
and surviving transfer sites, so placement evidence need not survive source
re-evaluation. A rebuilt attempt receives new occurrences and a new plan. Keep
source/invocation provenance for diagnostics, not as proof that the nth allocation
of two different attempts is the same allocation. Any feedback that genuinely
must survive still needs its own target, dependency and correspondence proof.
This does not claim that all current retained arena events are defective.

There are two completion questions, not a universal “done” flag:

1. Is the evaluated description semantically complete: legal uses, transfers,
   exits and boundary assumptions, with all remaining storage obligations named?
2. Is its exact program view ready for backends: physical assignment proved,
   storage work realized, captures resolved, and no discarded or unresolved edge?

The split must not let preparation repair illegally evaluated source. Both C and
libgccjit must consume the same completed result, not perform separate memory
semantics. We have not selected a new IR or settled all dependency scheduling.

## 8. Observations and checks, not replacement acceptance

[storage-probe.lua](storage-probe.lua) runs the actual frontend/evaluator with
`no_c = true` and the written call policy. It wraps `Builder.gs_alloc` and
`adopt_tenant`, restoring both and the policy even after failure. It observes
completed allocations and final `choose_owner` definitions; an “attempt” is a
function object seen allocating L/R, **not** a count of every evaluation/retry.

| Case | Allocation attempts observed | Final choose definitions | Result stacks | Other observation |
|---|---:|---:|---:|---|
| Inline, known true | 1 | 0 | n/a | L/R use distinct local indices 0/1 |
| Inline, dynamic | 1 | 0 | n/a | Same distinct local allocation pattern |
| `call`, known true | 2 | 1 | 1 | Dynamic flag absent; A changes from local to result storage |
| `call`, dynamic | 3 | 1 | 2 | A then B discovered as result allocations; flag stays dynamic |
| Element receives known call result | 4 | 1 | 1 | `adopted=false call_arena_ok=true`, then `adopted=true` |
| Element receives dynamic call result | 3 | 1 | 2 | `adopted=false call_arena_ok=false` |

Raw run: `build/logs/compiler-storage-probe-v4.txt` (empty stderr). Earlier raw
runs are preserved: v1 failed on the probe's Lua long-string delimiter; v2 failed
on an ambiguous `Grow U32 {}` spelling. Parenthesizing the type-constructor call
fixed that fixture. V3 completed the initial five cases; v4 adds the known-result
adoption control. Neither failure was a demonstrated compiler regression.

**Six staging cases completed.** No preparation, runtime attachment, C emission,
native execution or compiler subprocess ran. No replacement implementation or
allocation proof was tested. In particular, staged success does not prove safe
recursive placement, correct native release, or the no-copy promise.

Source anchors for the reasoning:

- `nua/memory.lua`: `Mem.stack_index`, `next_allocation`, `gs_alloc`,
  `register_slot`, `release_slots`, `move_owner`, `open_tenant`, `adopt_tenant`,
  `put_owner`, `S.stack_rewinder`.
- `nua/stage.lua`: `mark_moved`, `mark_held`, `check_usable`, `h.place_result`,
  `h.result_destination`, `h.finish_ref_moves`, `note_growth`, `end_place`,
  `h.end_frame_tokens`, `arg_key` and `build_function`.
- `nua/cgen.lua`: `plan_stacks`, result-region offsets and growth checks.
- `lib/storage.nua`: ordinary Nua growth, shared-position retirement and copy;
  `lib/storage_layout.nua:releaser`, `lib/stacks.nua:close_arena/reset`.
- `examples/nested_owners.nua`, `tests/errors.lua` and `tests/fuzz/storage.lua`
  were read, not run as acceptance suites.

## 9. What this narrows, and what is still owed

The nonrecursive owner-return witness now has an explicit holding/cleanup walk
and a candidate placement derivation that does not inherently require replay.
Physical numbering is distinct from semantic position, and quiet-window arena
placement does not itself change a local owner's borrow rules. These findings
constrain D02/D05/D06; they do not freeze them.

Before implementation, complete the following concrete arguments:

- **Result into shared storage — decided:** cross-position relocation is permitted
  (§5); ordinary ownership transfer remains no-copy. This is explicit user approval,
  not silent adoption of Goose's copying rules or exclusions.
- **Nua realization:** show how symbolic region captures/releases become ordinary
  Nua work with correct site ownership and a closed planning dependency (§4).
- **Move/loan and iteration completion:** trace old-header aliases, contents views,
  replacements, carried owners and accepted-child/rejected-parent endings through
  the same records, preserving current lifetime rules (§6–7).
- **Recursive and mixed-origin results:** complete result-region ordering and
  forwarded-argument/fresh-result cleanup, together with move/retirement summaries,
  on a surviving call graph. Classify necessary reconsideration separately from
  physical assignment.

These are design obligations now, not features outside a frozen scalar core.
The overall direction is now approved; [checked storage](../checked-storage.md)
records the new witness, terminating-path correction, remaining reference-result
gaps and cleanup proofs. These are not claims of replacement acceptance. The old
M1 table is historical, withdrawn scope discussion, not an instruction to exclude
native owners.

[goose]: https://github.com/aardappel/goose/blob/7b90f91d91845f4ef1712e16ed053f395e4e6e1c/docs/goose_spec.md
[goose-impl]: https://github.com/aardappel/goose/blob/7b90f91d91845f4ef1712e16ed053f395e4e6e1c/docs/implementation.md
