# Replacement compiler: implementation status

The implementation target is [compiler activities](../docs/design/compiler-activities.md),
with [syntax](../docs/syntax.md), [buffers](../docs/design/buffers.md), and
[tasks](../docs/design/tasks.md) owning the contracts. This inventory describes the
implementation, **not revisions to those contracts**. The old compiler remains separate.

Run `make test-next`; use `.local/bin/luajit next/test.lua program_lifetimes` for the
real-program lifetime-fact checks. Native tests build and execute C under `build/next/`.

## Construction-owned lifetime facts

`compile` returns both `program` and a revision-bound `Analysis`. Definition construction
publishes its accepted fragment's value/borrow facts, block entries, site snapshots, edge
rows and joins. Child adoption includes facts; rejected constructions do not contribute
facts to the published definition. Native parameter borrows and packed views have value
facts. Safe reference/view dereferences use `IndirectRoot`, not the raw-pointer escape.
Owner moves/releases emit their `Ends` events into the graph.

The lifetime verifier now consumes these facts instead of an empty table. It replays
`Moves`/`Ends` over the actual CFG, distinguishes acquisitions from inherited borrows,
and checks indirect accesses. In particular, it rejects a stale outer view used on the
next loop iteration while accepting a fresh loop-local view. Branch-edge owner transfers
are alternatives, not consecutive transfers. Missing analyses, mismatched revisions,
missing definition facts and missing borrow origins are refusals.

`tests/program_lifetimes.mua` also deliberately corrupts valid compiled graphs/facts and
checks that replay rejects them without changing the original product. Native execution
provides independent expected values for the positive cases.

**This is not backend readiness or completion of the lifetime subsystem.** Snapshots do
not certify their own correctness. `Analysis.contracts` now contains revision-bound native
contracts, but full aggregate/reference transport, lifetime completion, proof validation
and effect recomputation still need the work below. These facts are not yet an optimizer's
complete effect proof.

## Selected paths through control

The approved amendment in compiler activities §2.4 is implemented by `borrow_paths.mua`
and the evaluator. Branches and loop headers carry a selector and finite path coordinates.
Same-shape paths coalesce; nested selections flatten; loop agreement widens path shapes and
origins, not iteration identities or coordinate values. Held alternatives are rederived
through current headers only on the selected path. Stored alternatives remain fixed native
values, with their own invalidation origins. There is no runtime borrow object.

Reference-valued locals, inline returns, loop refresh/rebinding, break/continue exits,
nested-buffer views and selected-reference writes/calls have real-source coverage in
`tests/selected_borrows.mua`. Tests include inactive paths into empty storage, mixed
held/stored choices, 24 source roots, independent numeric expectations, and verifier replay
against deliberately invalidated graphs. Exported native result joins are also executed
through the C ABI. Local rebinding rejects nested-scope escapes under syntax §9.5
before loop agreement can accumulate identities for illegal loop-local origins.

Edge rows pair incoming contents with destination references, including internal reference
temporaries. Lifetime replay uses those rows, not borrow annotations on scalar coordinates.
Malformed/non-flat selections and mismatched origin unions are refused. `join_borrows` now
requires an explicit result form instead of accidentally selecting its first input's path.

## Current milestone: ordered boundaries and resident provenance

The approved memory-provenance amendment is implemented by `provenance.mua`:
`Stored(None)` records resident or unprojected component provenance, never an invented
pointer. Loads/extractions attach actual operands without reviving ended borrows. Canonical
payload/component places replace `FlowFacts.holds`; known writes replace their component,
while uncertain writes join possible contents. Buffer words use tracked element references,
not raw payload-pointer stores. Addressed locals remain resident across calls, writes,
branches and loop agreement, and resident owners are released. Payload facts travel with
owner moves without treating unused payloads as reads; references stored in records retain
fixed-pointer semantics.

`boundaries.mua` projects typed contracts and substitutes actual argument/component origins.
It interprets the accepted CFG in order, including repeated invalidations and nested calls.
Checks include trapping/nonreturning prefixes; only normal exits contribute caller facts.
Recursive call contexts reach agreement over the actual definitions, without unrolling caps
or a flat-summary fallback. Definition dependencies are rebuilt to agreement before publication.
Returned views/references re-root at recoverable caller paths; captured view ranges survive.
Effects through stored header references retain their captured borrow identity, even when
an aliased container slot is overwritten before the effect.

`tests/boundaries.mua` covers native execution, record-component forwarding, addressed locals,
known overwrite versus wildcard storage, aliasing, recursive/nonreturning groups and independent
verifier replay after callee mutation. The original clear–store–clear stale-view probe is now
refused; storing a fresh view after the final clear is accepted. Latest full check:
**`make test-next`: 136 passed, 0 failed.**

## Design-to-source gap inventory

| Area | Present | Remaining obligation |
|---|---|---|
| Hosting/evaluation | Mua host, partial supply, known/residual scalars, records, control, direct calls | Rest supply, hosted callbacks/protected propagation, capture/dependency validation; replace remaining ad-hoc activity outcomes with the specified protocols |
| Borrow flow | Held/stored selected-path joins, loop-carried references and views, nested-buffer paths, explicit invalidation and real graph replay | Full stored-reference/aggregate transport, including held views through stored header references; lexical `LifetimeStart`/`LifetimeEnd` completion and escape checking |
| Memory provenance | Resident component facts, pointerless provenance, strong/weak stores, load state preservation, resident-local branch/loop agreement | Extend component transport/proofs to the remaining aggregate forms and storage mechanisms; complete alias/provenance validation |
| Native boundaries | Ordered contracts and substitution, returned-borrow re-rooting, alias requirements, recursive CFG agreement, independent call replay | Complete interface-key/capture/dependency protocols, global/foreign/indirect boundaries, owning ABI/parameter-payload transport and remaining component-path coverage |
| Owners/buffers | Nua allocator and moving buffer words; nested release and selected conditional moves tested | Complete linear aggregate/partial-move representation, initialized-prefix proofs, pinned storage, complete allocation-ledger and trap-recovery acceptance |
| Language coverage | Type descriptors include sums and fixed arrays; `Str` descriptor exists | End-to-end sums/matching, fixed arrays, static string literals and Nua Text words; descriptors alone are not implementations |
| Preparation | Graph/type/lifetime checks on emitted C programs | Optimizer, budget insertion, complete effect/alias recomputation, `task_access`, `ready`, revision-matching readiness certificates |
| Tasks/platform | Storage mapping/copy mechanisms | Native context/stack mechanisms, Nua scheduler/waits, foreign extents, task/channel/slot acceptance |
| Backends/diagnostics | C for the implemented subset; source-line errors | Shared prepared-IR C/JIT adapters, structured related-location diagnostics and the full independent acceptance set |

The next end-to-end work is **remaining reference/aggregate transport and lifetime completion**,
not an optimizer over incomplete facts. Then finish sums, arrays and Text, the remaining boundary
protocols, preparation, scheduling and both backends. Cutover requires the documented acceptance obligations;
passing the current subset does not establish them.
