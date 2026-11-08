# Checked storage: the chosen design

**Approved direction.** The user accepted this design with “yes lets do this !”
after asking for an overall design with actual choices. This replaces the open
choice about cross-position result copying in the revision 4
[storage derivation](compiler-inventory/storage-derivation.md). It does not revive
the withdrawn scalar M1, exclude owners from the core, or claim that a replacement
compiler exists. [Syntax](../syntax.md) owns language/ABI contracts;
[architecture](../architecture.md) distinguishes this target from current code.

**Subsequent approval:** [affine regions, completion and native task execution](region-completion.md) supplies the complete physical/boundary architecture. It replaces this design's earlier fixed-stack/no-copy assumptions, while retaining the safe typed-buffer foundation and Nua algorithms. The decisions below are reconciled to that approval; §5 preserves the earlier experimental evidence, not validation of the new runtime.

## 1. Decisions

- Use affine runtime regions with private stable standalone reservations and independently reclaimable nested blocks. A type has finitely many logical storage positions, not a fixed number of physical stacks. The allocator is heap-like reservation/free machinery, with no tracing GC, reference-counted language ownership or implicit borrow promotion.
- Use one checked typed-buffer foundation. `Grow T` exposes it directly; `Text`,
  slot stores and maps compose it. `Buffer T` was a provisional design name, not
  a new public type or a second implementation alongside `Grow`.
- Container algorithms, capacity policy, initialization, copying, compaction and
  destruction remain ordinary Nua words. Lua constructs types and checks the
  general storage operations; C supplies only necessary platform mechanisms.
- Container authors use initialized typed storage and checked places, not raw
  pointers, forged headers, allocation indices or manual retirement annotations.
- Actual owner moves/returns transfer cleanup and permit relocation. Standalone handoff normally copies no payload; fragment detachment or destination normalization may copy. Old contents loans end uniformly, even with copy elision. Joins/backedges and compiler-only transport of the same installed holding are not new source moves. Direct construction/adoption is an optimization, not correctness.
- Construction activities initialize an element, publish it, then lend it to the
  body. A callback return does not undo the append. Activity-wide atomicity,
  general rollback and a deferred-constructor subsystem are not implicit contracts;
  the storage kernel's bounded publication is a separate consistency guarantee.
- Evaluate ownership, lifetime and stable/relocatable guarantees in the integrated evaluator. Realize typed region operations on the same IR without a root-bank/physical-index placement fixed point or source replay. Genuine move/borrow/control-summary changes may require reconsideration.
- Prepare/check/build privately, publish through bounded nontrapping/nonsuspending COMMIT, then retire obsolete resources. This storage-consistency guarantee does not roll back earlier source effects or an activity's already published append. Preserve logical compaction timing, including native caller completion.

The source semantics remain “supply what you know, evaluate in place, keep what
remains, share with `call`.” Owners remain runtime storage; known control and
ordinary Nua algorithms still specialize. No new exclusive-borrow rule is added.

## 2. The safe surface and its implementation boundary

The buffer has an initialized prefix and inaccessible spare capacity. Its
representation is not an ordinary user-writable record of pointers and lengths.
There is no public general uninitialized-slot API in this design.

| Operation | Checked contract |
|---|---|
| Create | Empty owned storage, with an identified cleanup owner |
| Index / view | Bounds-checked access to initialized contents, with its borrow dependencies |
| Append | Initialize a new element before exposing it; consume an owning argument |
| Replace | Evaluate/capture before ending what it may read; prepare a complete replacement, commit the header/custody/loan transition, then retire obsolete resources |
| Truncate | End the removed suffix and its borrows before any slot reuse |
| Pop | Return the last value/owner under the cross-position cost rule, then end its old position |
| Reserve | Ensure capacity without changing initialized length; apply the storage mode's invalidation contract |
| Copy | Explicit duplication, recursively for owning contents |
| Move / scope completion | Transfer cleanup with ownership, or end what the scope still owns |

An owning element is accessed by reference, not duplicated by copying its header.
Views do not provide an alternate way to duplicate owners. A sparse store uses
`Empty | Occupied T`: every cell is initialized, including vacant cells. Generation
and instance checks for persistent IDs are ordinary library work, separate from
reference lifetime safety.

The general compiler capabilities establish storage, obtain checked access,
initialize/end stored values, and transfer ownership. Ending or replacing a value
ends its affected borrows as part of the operation. It is not an optional `retire`
annotation supplied by each container author. The trusted Nua storage kernel must
couple its physical operations to those checked transitions; algorithms do not
move into compiler Lua or opaque C. Raw memory access remains an explicit trusted
implementation/foreign boundary, not a requirement for writing a container.

This is a target interface, not a claim that the current unsafe-grade
`owner_type`, `Mem.view`, `retire`, `store_owner` and layout hooks already provide
it. The prototype below composes current safe `Grow`, sum and reference operations;
it does not replace those internals or add a public `reserve` method.

## 3. Borrow and growth rules

- Borrows cannot extend the lifetime of their backing storage. Slots reused later
  are new occupants; old borrows never revive. Earlier scalar observations remain
  values, not loans of the later contents.
- Aliases are allowed. A later use after invalidation is rejected; an unused old
  borrow does not by itself prohibit mutation.
- Stable standalone growth preserves existing contents views. Potentially
  relocating shared-position growth ends affected contents views, regardless of
  whether one execution fits capacity. Checked selectors can retain only borrows
  proved unaffected. Compaction must also preserve its specified invalidation.
- A reference's storage guarantee must survive binding, branches, matching,
  aggregate storage, returns and native boundaries. It is semantic information,
  not a guess based solely on the current place-table shape.
- Joining different reference targets must retain their possible origins and the
  guarantees common to them. If a target may be shared-position storage, it cannot
  be treated as stable. This must not silently impose shared-position semantics on
  a reference proved to name standalone storage.
- Native references remain pointers; slices remain pointer/length values. These
  facts do not require per-borrow runtime objects. Bounds, occupancy and generation
  checks remain runtime checks when not provable while specializing.

Moving contents does not automatically redirect an old reference to the source
header. Result/boundary summaries must preserve loan origins as well as moves and
invalidation; exact target identity and a lifetime bound are different facts.

## 4. Owner results and cleanup

These walks now use the approved [region/completion protocol](region-completion.md), not fixed-role suffix marks.

**Two live candidates.** A and B have independent growing storage. Transfer the selected complete holding and end the other on its actual edge. Capture precedes cleanup that could change the value; no source replay predicts the winning candidate.

**Recursive forwarding and combination.** A result hands its region to the receiver before the callee frame ends. Both an older and a newer independent result may grow; neither obstructs the other. Combining results can require fragment transfer, but needs no depth-specific ports or shared result-stack rewind. Runtime resource counts follow actual live ownership; type/native interface width stays finite.

**Mixed argument/fresh origin.** Return the selected holding's actual authority, release unselected scratch/reservations on their paths, and update receiving custody. Neither equal headers nor empty payloads reconstruct a hidden branch's cleanup history.

**Partial moves and shared extents.** Independently movable fields normally have independent regions. A genuinely indivisible backing extent has one explicit custodian. Detach escaping fragments before that custodian ends; it alone releases the shared backing. A moved fragment cannot reclaim a sibling, and a returned frame cannot remain the custodian. No reference count or source exclusion supplies the missing authority.

**Completion and recovery.** Native results are complete exit holdings before required source/activity completion, including legal waits. Transfer at the prescribed source point, then apply pending native logical cuts before caller continuation/returned-borrow validation. Durable domain/operation records make plain-entry trap cleanup independent of abandoned frames and preserve complete global/outer targets. Both backends consume these same Nua-realized operations. Rejected compiler construction discards descriptions/code, not runtime resources.

These mechanisms are selected; their kernel implementation and independent lifetime/reclamation/recovery tests are still required.

## 5. Executable witnesses and actual results

**Historical checks of the earlier compiler/design.** These results and raw logs are preserved unchanged; no new region allocator or task-context execution was tested.

[examples/checked_storage/slots.nua](../../examples/checked_storage/slots.nua) constructs a
small generic sparse buffer from `Grow (Empty | Occupied T)`. Its `add`, `borrow`,
`replace`, `remove` and `build` operations use no raw pointers or compiler storage
hooks. Indices intentionally name reusable slots, not persistent IDs. This is a
design witness, not a new production `Store` implementation.

[checked-storage-probe.lua](compiler-inventory/checked-storage-probe.lua) exercises
construction, scoped access, replacement, reuse, explicit copy, owner movement and
shared calls. Current result: **2 cases staged, 5 expected rejections** (removed or
reused contents, nested growth, moved owner use, escaping local borrow). It does
not execute these algorithms natively or prove their runtime values/cleanup.

The example's ordinary `get -> Ref T` is deliberately retained as a blocked
witness, not replaced by a rule that access must always use callbacks.
[reference-result-probe.lua](compiler-inventory/reference-result-probe.lua) exits
nonzero for **two unmet requirements**:

1. The inferred result of a match rejects `Ref T` even when an occupied arm returns
   a legal payload borrow and the empty arm traps.
2. A typed local receiving a `Ref Text` selected from two shared-position fields
   stages a view use after growth instead of rejecting it. Current reference
   materialization loses the shared-position guarantee. Merely removing the first
   restriction also exposed this lost guarantee; that attempted change was removed.

The scoped-borrowing checks are not acceptance of these defects. Reference-return
lookup remains required. This is the next concrete primitive-level blocker.

[owner-completion-probe.lua](compiler-inventory/owner-completion-probe.lua) reports
**3 staged cases and 1 expected rejection**. Recursive forwarding has one result
stack and one caller pre-call capture; recursive combination has two of each.
Mixed argument/fresh return has one result stack and `returns_param`, with no
pre-call capture in the current implementation. The last observation is not a
cleanup correctness proof. The older-result growth witness was rejected as required by the old shared-stack model. The approved independent-region architecture removes that obstruction; this historical rejection is not its desired acceptance result.

A small production correction makes `trap` end its path and keeps an inline word
with no returning path from fabricating a caller continuation or clearing its
state. [tests/trap_staging.lua](../../tests/trap_staging.lua) passes **8 staging/IR
checks**: root/inline traps, two trapping arms, a surviving return, matching,
callbacks, borrowed returns and ordinary Unit fallthrough. No general bottom type,
foreign noreturn annotation, or new retry transport was added.

Raw logs are retained under `build/logs/`: `checked-storage-probe-v1` through `v7`,
`reference-result-probe-v1`/`v2`, `owner-completion-probe-v1`, and
`trap-staging-v1` through `v3` (each with `.txt` / `.stderr.txt`). Earlier failed
fixtures include shorthand-handler and module-application parsing, and a scalar
Ref return spelling; later failures include the actual continuation and reference
facts above. They have not been overwritten or reclassified as passing tests.
Final runs after moving the example module into its own directory are
`checked-storage-probe-final`, `reference-result-probe-final` and
`trap-staging-final` (same log suffixes). The reference probe still exits 1 with
two gaps. An additional `no_c` smoke check stages the existing
`examples/immediate_matches.nua` (11 functions), recorded in
`storage-design-immediate-matches.txt`; this is not native acceptance.
The trap regression is registered in `tests/run.lua`, but that broad runner was
not executed.

All these runs use `no_c = true`: no preparation, C emission, native execution or
compiler subprocess. No broad acceptance suite was run.

## 6. Next implementation obligations

1. Preserve reference target/storage guarantees through result joins, bindings and
   boundary summaries; make both reference-result witnesses meet their required
   outcomes without weakening stable-storage guarantees or bypassing lifetime checks.
2. Implement the approved region/custody, typed prepare/commit/retire and recovery protocols; check recursive/mixed-origin/partial-move cases and accepted-child/rejected-parent isolation against independent ledgers.
3. Build the checked buffer foundation and migrate a complete container subsystem
   to it in Nua. Do not retain unsafe per-container layout hooks as the new public
   library-author interface, or create a compiler kind per container.
4. Realize these operations and task budget effects through the replacement's one evaluator/IR, preserving source evaluation, knownness and `call` sharing. No bounded physical placement analysis may reject a required valid cohort.

These steps implement the approved complete architecture, not the old scalar-only freeze. API spelling and concrete record layouts remain implementation work; custody, completion ordering and native budget suspension are no longer unspecified mechanisms. No hidden old-evaluator fallback is licensed for a replacement path.
