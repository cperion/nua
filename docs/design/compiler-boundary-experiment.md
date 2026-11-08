# Component completion across explicit native-call boundaries

This is the next [completion-design experiment](compiler-completion.md), following
[boundary-owned capture and reset](compiler-completion-experiment.md). It tests a
candidate contract, **not a production ABI or compiler implementation**.

## The contract tested

A holding and the authority to restore its storage are distinct:

- A native argument transfers its holding to the callee. A native result transfers
  the surviving holding back to the caller.
- The receiving boundary owns the saved marks. A callee receives typed position
  and mark operands describing storage it may use, but no authority to rewind
  beneath another protector. The probe calls this a *lease*: compiler facts and
  native operands, not a runtime ownership object or language feature.
- A result component carries its incoming component obligations plus the fresh
  footprint of that call. Its sibling's obligations are not included.
- Ending that returned component in the receiving frame realizes its resets,
  even while the sibling remains live. A scalar-consuming call is completed by
  its receiver immediately after return.

This is not accidental whole-function retention. The successful witnesses observe
the sibling **after the other component's actual reset instructions have run**.
Leased frames have no reset authority; a deliberate callee reset is refused even
when that callee has already ended its argument logically.

## Construction and realization

[The executable probe](compiler-boundary-probe.mua) uses the activities probe's
existing checked program family. It adds `Call`, per-call allocation instantiation,
explicit callee definitions and ordinary `U64` position/mark operands. Calls stay
calls in the produced program: they are not inlined fixture closures.

The evaluator's call handler instantiates outcomes derived from the completed
callee graph. It transfers actual incoming holdings, preserves their origins,
records fresh allocations separately from operand custody, and applies ending
and result effects. This still enumerates finite acyclic alternatives; it is not
the proposed compact relational or recursive analysis. Fresh-instance identities
must not alias existing caller allocations.

The storage activity derives incoming component widths and fresh footprints from
those graphs. A native definition's extra position/mark requirements are ordinary
typed parameters. For example, the printed output includes:

```text
call relay.leases_1(owner, position, original_mark)
call relay.leases_2(owner, position_A, mark_A, position_B, mark_B)
```

The second form forwards an argument-or-fresh result whose completion includes
both candidates. Relative completion width—not an absolute stack index—is part of
this experiment's storage variant key. This is an exposed experiment limitation,
not a selected production specialization or ABI rule.

For field swaps, owner block arguments acquire corresponding position/mark block
arguments. Each incoming edge supplies all three from the **same component**.
The checker rejects a graph that keeps the selected header but supplies the other
field's completion operands, even though its scalar SSA types are valid.

Fresh caller-owned captures normally occur before allocation or at the actual call
site, after argument evaluation. The later [join experiment](compiler-join-experiment.md)
hoists selected captures when an absence proof justifies extending a component.
A nested call forwards its enclosing reserved region's marks rather than recapturing
above retained bytes. Fresh local allocation sites
inside a leased definition may share a position only when the derived lifetime
interference relation proves they never coexist. Imported components and separate
calls' footprints are not merged by that optimization.

This permits a dead local prefix and a later returned allocation on the same
position. The returned cell begins four bytes above the original mark; completion
must still restore the original mark, not that later cell's base. Conversely, two
live fields cannot share a position in this nonrecursive standalone-storage subset.

Capture/reset work is still evaluated from the existing ordinary
[Nua storage listing](compiler-completion-words.nua), through `nua.front` and the
same evaluator. The previous probe's helper-instantiation activity is reused,
not copied into another backend or reimplemented as a Lua reset algorithm.
`nua.stage` is never loaded.

Planning owns fresh output, cached variants and active work. Replanning does not
execute fixture bodies or change previously published definitions, including
callees. A rejected planning activity closes; its accepted output remains intact.

## Independent call-frame ledger

The ledger executes the resulting IR with separate value environments for each
call and a persistent storage world. A callee receives numeric native argument
values, not a reference to its caller's evaluator frame. It checks:

- each position's top, protected older prefix and exactly one completion authority;
- initialized allocation intervals, current custody and surviving borrows;
- transfer at call entry and return, with no holding left in a returning frame;
- incoming positions covering the actual holding and retaining the original marks;
- no reset from a leased frame, under a live sibling, or to a later header base;
- exactly-once completion before the receiving boundary ends.

The ledger does not reuse the evaluator's ownership predicates or call summaries.
Position-dependent prefixes deliberately make different saved marks numerically
different, so a mark swap cannot hide behind every position starting at zero.

Six successful witnesses cover an unchanged field round trip, a swapped-field
round trip, argument-or-fresh return, forwarding that mixed result through another
shared definition, a retained-prefix result, and consuming one field while its
sibling survives. Each runs both Boolean outcomes with two prefix seeds: **24
prefix/branch checks**. Forwarding reaches three frames and retains three calls.

Thirteen deliberately invalid plans/IR mutations are refused, including missing
or duplicated completion, premature reset, stolen callee authority, call-site
recapture, a mark left in a returning frame, mismatched swap operands, overlapping
live positions, a lost retained prefix, missing native operands, forged allocation
identity, a missing incoming contract and reuse of a failed planning activity.
An additional invalid-source case rejects a borrow used after a consuming call.

## The original unequal-width failure, now closed

The first fixed-width component representation failed this valid join:

```text
left field initially carries one completion position
if flag:
    left = call argument_or_fresh(choice, move left)  -- two-position envelope
else:
    keep left                                       -- one-position envelope
observe/end left
observe the still-live right field
```

`flag` and `choice` are independent native inputs. The semantic graph verified, but
storage construction originally failed with:

```text
unequal component widths need another normalization
```

It was kept as a **separate exit-1 valid-program acceptance witness**, never counted
as an expected rejection. The [join follow-up](compiler-join-experiment.md) now closes
it without changing its source: capture the additional reserved role before the
branch and prove it has not been acquired on the incoming path without the call.
`--unequal-components` now exits **0**, exercising all eight prefix/Boolean combinations.

This is not general padding. The follow-up preserves a new nonzero valid-program
witness that swaps an already-long component with a short sibling: the extra role
then belongs to the other field and cannot be treated as absent. No padding ABI or
runtime cleanup tag has been adopted. These are further design probes, not a reason
to start the replacement compiler.

## Running and evidence

From Nua's root, using the neighboring Mua checkout:

```sh
mkdir -p build/compiler-boundary-probe
.local/bin/luajit ../mua/mua.lua docs/design/compiler-boundary-probe.mua
.local/bin/luajit ../mua/mua.lua docs/design/compiler-boundary-probe.mua --unequal-components
```

Results at the original boundary milestone (historical logs retained):

- Ordinary boundary run: **exit 0; 6 witnesses, 24 prefix/branch checks, 13 invalid
  plan/IR rejections and 1 invalid-source rejection**.
- Unequal-component acceptance: **exit 1**, with the normalization diagnostic above.
  This was an unmet valid-program requirement, not a passing negative test.
- Previous activities probe: **30 constructed cases / 31 expected rejections passed**.
- Previous completion probe: **6 witnesses / 36 prefix/branch checks / 13 invalid
  plan/output rejections / 2 known Nua checks passed**.
- Original `--edge-reclamation`: **exit 0; 31 constructed cases / 31 expected
  rejections passed**, including its independent storage ledger.
- Formatter and whitespace checks: **passed**.

Raw evidence is preserved under `build/compiler-boundary-probe/`. Final runs are
`run.log`, `unequal-components.log`, `activities.log`, `completion.log`,
`edge-reclamation.log` and `format.log`; `06-unequal-components.log` retains the
first observed valid-program failure. Current reruns live separately under
`build/compiler-join-probe/`: the ordinary boundary suite still passes, and the
original unequal-component acceptance now passes. See the [join report](compiler-join-experiment.md)
for its additional checks and the historical exchanged-component failure. The
[regional follow-up](compiler-region-experiment.md) subsequently closes that separate
acceptance with boundary-owned relations and tests finite cyclic region ports.

No C/libgccjit backend compilation, native Nua execution, production compiler
change, dependency-pin change or ABI adoption is part of this experiment. The
previous activities and completion probes remain separate acceptance checks.

## Remaining limits

These are residual call definitions and explicit native operands in the proposed
IR, checked by an independent frame ledger—not emitted or executed C. Owners are
still synthetic fixed-size cells; fields are separate places, not real aggregate
headers. The source fixtures are staged closures. Only storage helper words use
the actual Mua/Nua host here; general hosted `call`, current-header mutation/move,
real container layout and platform bindings remain unproved.

The receiving caller in this experiment closes the entire component before its
own scalar exit. Leases pass through a finite call DAG, not recursion. No finite
recursive completion-width agreement follows from these successful forwarders;
repeated fresh-result combination may keep enlarging the envelope. Cross-call
trap unwinding, native reference summaries, general temporary completion and
foreign/task boundaries also remain open.

The result supports a component-relative authority/operand contract for these
bounded cases. It neither proves all partial moves partition physically nor
solves the case of one genuinely unpartitionable extent whose protectors escape
to different lifetimes. **Not ready for production replacement implementation.**
