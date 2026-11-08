# Boundary-owned relations and finite recursive region ports

This continues the [join experiment](compiler-join-experiment.md) and
[completion proposal](compiler-completion.md). It tests a different contract, not
another padding rule for owner-position vectors. The
[regional probe](compiler-region-probe.mua) closes the original exchanged-component
acceptance and exercises cyclic native-call graphs over the **same program IR**.

**Historical candidate contract, not the adopted ABI or a production implementation.** The subsequently approved [affine region/completion architecture](region-completion.md) uses independently reclaimable runtime regions rather than this experiment's fixed fresh ports.
[Syntax](../syntax.md) remains authoritative. In particular, finite agreement here
is not a proof of general cyclic placement, source specialization convergence, or
full owner/header integration.

## 1. Authority belongs to the receiving boundary

The receiving boundary owns a finite table of physical positions and their original
marks. Its component relation says which outstanding obligations accompany each
current holding. Moves change that relationship, not the marks or the authority.

For the unchanged exchanged-component source, name the original positions `A`, `B`
and the argument-or-fresh call's additional position `X`:

| After the swap join | Left's obligations | Right's obligations |
|---|---|---|
| No swap | A, X | B |
| Swap | B | A, X |

`X` follows the long component even when the call returns its argument and `X` has
no payload. Ending the selected left component does not take `X` from the right.
The surviving right component is observed after the left's actual resets.

The compiler transports membership through **the same CFG edges as the owning
headers**, using Boolean block arguments where alternatives differ. Positions and
marks stay at the receiving boundary. There is no requirement that the two owner
alternatives carry equal-length native vectors.

These guards are real residual SSA data, not merely static annotations. This
experiment chooses local conditional cleanup; it does **not** prove that these
extra Boolean operands are minimal or necessary in every lowering. It introduces
no heap ownership record, reference count, finalizer closure, or owner ABI tag.
Neither the guards' encoding nor the extra native position parameters below are
adopted language ABI decisions.

### Unused reservations and exits

The receiver captures its distinct reserved roles at entry, before any allocation
or call can acquire them. Unexecuted allocation/call sites do not fabricate owners
or payload. Their reservations remain boundary-owned until completion.

A finite per-role pending state follows CFG edges too. Ending an owner conditionally
restores its related roles and updates this state; return/trap completion restores
remaining reservations. This handles an early exit without either abandoning an
unused reservation or unconditionally resetting a role already completed elsewhere.
It does not establish general cross-call trap unwinding.

All captures and resets still come from the ordinary
[Nua storage words](compiler-completion-words.nua), through `nua.front` and the
experimental evaluator. Boolean control transport is compiler work over the existing
IR, not a replacement Lua implementation of a storage algorithm.

## 2. Calls do not receive an argument's completion history

An incoming owner supplies its current payload/header. The receiving caller retains
its associated completion relationship. The callee receives only its fixed fresh
region-position parameters in addition to its ordinary parameters; it receives
neither the caller's original marks nor a flattened incoming completion vector.

The candidate result contract remains conservative:

```text
result obligations = supplied owning arguments' obligations + fresh region footprint
```

This union is evaluated in the caller's relationship domain. A scalar-consuming
call completes that envelope on return to a receiving boundary. An owning result
carries it forward logically. A borrowed native frame does not acquire permission
to reset to its caller's original mark.

Thus `relay` has just its owner parameter. `argument-or-fresh` has its Boolean,
owner and one fresh position parameter, even when nested callers supply owners
whose completion histories differ. Forwarding keeps explicit calls and their
ordinary effects; it does not inline or replay source to avoid a contract.

The ledger's synthetic cell position models access through the current owner.
This is **not yet implementation evidence for real Nua header layout or mutation
followed by movement**. No production header field is added or removed.

## 3. A finite agreement domain, established before iteration

The input is a sealed finite registry of the existing `Definition` nodes. `Call`
continues to name its target; recursive definitions do not contain cyclic Lua tables.
The graph checker can resolve calls through this registry. Intraprocedural CFGs
remain acyclic in this experiment.

The activity computes strongly connected components (SCCs) of the call graph.
Processing the condensation graph from callees to callers, it freezes each SCC's
role universe from:

1. actual `BeginOwned` sites in its definitions;
2. the already finite footprints of outgoing calls to other SCCs, instantiated per
   lexical call site.

An internal recursive edge substitutes the **same relative ports**. It never
prefixes a new call-depth identity or appends an incoming owner's history.
Per-definition support then grows monotonically within that frozen universe.
For an SCC with `D` definitions and `R` roles, at most `D * R` facts can be inserted.
The implementation asserts the bound; it does not use an iteration limit, drop
obligations at a cutoff, or assume that observed concrete recursion depths bound
compilation.

Each source definition gets one prepared definition in this experiment, not variants
keyed by incoming completion width. This establishes termination of **this role
support analysis over an already finite program**. It does not establish finite
binding-time specialization of arbitrary hosted source, general lifetime-summary
agreement, or safe widening of known values.

Nor does a finite role set prove that a placement is safe. The current policy gives
distinct sites/acyclic call instances distinct ports and reuses an SCC's ports on
recursive edges. The independent ledger still refuses simultaneously live allocations
sharing a position. No broad ancestor-sharing exception was added to make these
witnesses pass.

## 4. Cyclic evidence and its exact scope

Four fixtures cover self and mutual recursion, each in two forms:

- **Forwarding:** create a cell; end it before descending; forward the base frame's
  surviving cell through all returning frames.
- **Replacement:** consume the incoming owner, create its replacement, and pass that
  owner down the recursive edge. On a reused port the old input ends before the new
  allocation. The outer receiver still retains the initial argument's obligation.

Each runs at depths `0, 1, 2, 7, 31`, with prefixes `0` and `64`. Self recursion uses
one fresh port; mutual recursion uses two. Native parameter counts do not change
with depth. At depth 31 the ledger visits 33 frames including the receiver.
The returned cell's actual base lies above the ended recursive prefix; final
restoration uses the receiver's original marks, not that later base. An independent
sibling survives those resets and is subsequently observed.

**These cyclic fixtures are built directly in the existing IR**, with declarative
may-origin facts. They are not hosted recursive Nua source accepted by a finished
recursive evaluator. The existing path-enumerating lifetime analyzer is not run on
their cyclic call graph. Graph checks, finite support agreement and concrete ledger
runs are distinct evidence; none is mislabeled as a general source-lifetime proof.

## 5. Independent checks, not trusted relation annotations

The boundary ledger now has an explicit regional protocol alongside its earlier
lease protocol; neither is a fallback for a failed plan. Each call still receives a
fresh native frame environment. All original mark, custody, protected-prefix,
live-sibling and exactly-once checks remain.

For the new protocol the oracle derives a concrete obligation set from actual owner
transfers and actual fresh-port arguments. It compares the receiver's claimed
relations against that set, in both directions. In particular, covering the current
payload alone is insufficient: an empty obligation can still be lost or stolen.
These concrete sets exist **only in the test oracle**, not in emitted owner headers
or runtime containers. Allocation identities include the dynamic frame, so a later
execution of the same site cannot revive a loan of ended contents.

Thirteen invalid-plan/IR mutations are refused:

1. Lose an empty obligation at a join.
2. Steal the sibling's empty obligation.
3. Transport guards on a different selection from the owner.
4. Omit a native position operand.
5. Give a fresh call footprint the live sibling's position.
6. Capture after the call's acquisition, despite valid SSA dominance.
7. Abandon an unused reservation.
8. Complete an empty reservation twice.
9. Restore with another role's original mark.
10. Let a recursive frame exercise final reset authority.
11. Replace the receiving mark with a recursive recapture.
12. Invent a depth-specific recursive position.
13. Observe an ended loan after a later recursive instance of the allocation site.

Replanning compares root/callee output, including printed relation facts. Construction
counts and source snapshots check that planning does not replay the acyclic source
closures. A failed planning activity does not change accepted output or contaminate
a later preparation. No old evaluator is loaded.

## 6. Focused results

The regional suite passes **11 witnesses / 120 prefix/input checks / 13 invalid-plan/IR
rejections / 2 known unsigned checks**:

| Witnesses | Checks |
|---|---:|
| Original unequal join | 8 |
| Original exchanged-component source | 8 |
| Swap before join, with forwarding | 16 |
| Nested unequal joins | 16 |
| Join inside a native definition | 8 |
| Retained work in an argument-or-fresh call | 8 |
| Early scalar exit | 16 |
| Self/mutual recursive forwarding | 20 |
| Self/mutual recursive owner replacement | 20 |

The acyclic retained-work case uses separate site ports in this planner; it is not
claimed as evidence for coalescing those two sites. The cyclic cases independently
check returned data above a retained prefix on a reused port.

From Nua's root, using the current neighboring Mua checkout:

```sh
.local/bin/luajit ../mua/mua.lua docs/design/compiler-region-probe.mua
.local/bin/luajit ../mua/mua.lua docs/design/compiler-join-probe.mua --exchanged-components
```

Both commands exit **0**. The separate exchanged acceptance passes all **8** checks.
The original edge-reclamation and unequal-component acceptances also exit **0**.
The existing ordinary suites retain their results: activities **30 / 31**;
completion **6 / 36 / 13**, plus **2** known Nua checks; boundary **6 / 24 / 13**,
plus **1** invalid-source rejection; joins **6 / 72 / 8**.

Evidence is under `build/compiler-region-probe/`: `region.log`,
`exchanged-components.log`, `edge-reclamation.log`, `unequal-components.log`, the
ordinary-suite logs, incremental review diffs and `format.log`. Numbered trial logs
retain intermediate results and the Mua juxtaposition error encountered while
constructing the test driver. Earlier failure logs under `build/compiler-join-probe/`
are not overwritten. The current `tools/mua.lock` pin is unchanged.

## 7. Decision and limits

This is evidence for separating **boundary-owned completion authority**, **local
component relations**, and **fixed callable fresh ports**. Incoming ownership
history need not determine native arity. The exchanged witness and these cyclic
cases no longer require an unresolved vector normalization.

It is not yet a complete completion architecture:

- Multiple live protectors of an unpartitionable extent and recursive combination
  need a justified shared custodian or partition. The current single-component
  obligation rows and conservative placement policy do not establish that case.
- Borrowed frames in these tests never rewind. General temporary/scalar-call cleanup
  can need nested suffix marks and restricted subregion authority while older data
  survives. Retaining all work until the outer return is not a general solution.
- Intraprocedural loop backedges, alias-written carried places, lifetime-summary
  reconsideration and binding-time specialization need their own finite contracts.
  A finite fresh-port support set does not solve those analyses.
- Real hosted owner-header mutation followed by movement remains untested here.
  The cyclic sources are IR fixtures; the ownership values are synthetic cells.
- General aggregate returns, native reference summaries, early inline owner returns,
  foreign/task boundaries and cross-call trap cleanup remain outside this evidence.

These are not source-language exclusions. A future valid witness that the candidate
cannot realize must remain a separate failing acceptance, not become an expected
source rejection or a disabled test.

**The architecture-first requirement has since been met** by approval of [affine regions, completion and native task execution](region-completion.md), including the correction preserving seeded no-worker execution. This bounded experiment did not establish that architecture; its unsupported valid cases were not adopted as language exclusions. Its fixed-port ABI remains experimental. No production compiler, backend, dependency pin or ABI implementation changed in this milestone, and no C/libgccjit campaign or native Nua execution was performed.
