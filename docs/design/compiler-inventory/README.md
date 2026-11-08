# Compiler rewrite inventories

**Current architecture:** the user has approved [affine regions, completion and native task execution](../region-completion.md), integrated with [compiler activities](../compiler-activities.md) and [checked storage](../checked-storage.md). Dynamic independent regions replace fixed-stack placement; actual owning transfers cut old contents loans; native task contexts preserve seeded no-worker execution. The architecture-first prerequisite is met, not the implementation/validation obligations. The revisions below remain evidence, not competing target contracts.

**Revision 5 history — overall storage design approved.** The user accepted the concrete
[checked-storage design](../checked-storage.md): stack-backed ownership, one safe
typed-buffer foundation, ordinary Nua containers, automatic lifetime effects,
permitted cross-position result relocation and late physical placement. The old
scalar M1 remains withdrawn; this is not a claim that the replacement compiler or
all cleanup proofs are complete. A safe-library witness, focused owner-completion
observations and a small terminating-path correction now accompany the design.
Reference-result checks expose two remaining gaps, not accepted language refusals.
No C/native compilation or broad suite was run.

**Revision 4 history:** [storage derivation](storage-derivation.md) worked through
logical allocations, destinations, moves, releases and reconsideration. Its six
staging-only observations remain unchanged; revision 5 resolves the former
result-to-element cost question without retroactively claiming native acceptance.

**Revision 3 history:** The user challenged
the proposed memory-model deferral and feature exclusions immediately after the
assistant recorded a scoped freeze. That freeze is withdrawn; M1's scope and its
memory-model integration are not agreed. Baseline: Nua `6f47a4bb`, Mua `f74545c`.
Revision 1's inventories remain source evidence; revision 2 derived mechanisms
from Nua's problems. Revision 3 revisits construction ownership using both guides
and focused experiments. Actual evaluator traces now distinguish loop formation,
state discovery, header agreement, exit reconciliation and function sharing.
Section 3 states a candidate loop-completion contract. The user has adopted its
language rule: direct access and aliases observe the same current contents in
known and residual rounds. The known-round copy discrepancy remains unfixed;
this approval does not freeze the construction design.
Construction handoffs and a scoped source-to-C-text milestone are now proposed
in derivation §§6/8. D03 proposes retaining the existing targeted transport
provisionally, not the withdrawn new unwind framework or a coroutine driver.
The ownership contract and milestone remain proposals. Temporary implementation
limitations are not new language refusals. `review.md` records the reopened decision.
The earlier [source map](../compiler-map.md) is the reading narrative. Curate this
review surface rather than maintaining competing designs.

> **Supply what you know. Evaluate in place. Keep what remains. Share with `call`.**

Application, evaluation, residualization and materialization are responsibilities,
not a requirement for four modules. A word is not a native function. Saturation
executes its body; normal application has no function boundary to eliminate.
Materialization preserves specialization and introduces a residual boundary.
Ownership, effects and mutation participate in that evaluation.

## Reading order and authorities

0. [Approved region/completion architecture](../region-completion.md), [compiler activities](../compiler-activities.md) and [checked storage](../checked-storage.md): the integrated compiler, storage and task contracts, safe library foundation and implementation obligations. The historical M1 and bounded placement proposals are not the current direction.
1. [Problem-first derivation](derivation.md): branch, alias-written loop and owner
   result; mechanisms they require, simplifications and counterexamples. Section 3
   decodes [actual evaluation traces](evaluation-trace.lua) and
   [nested-loop/alias probes](loop-boundary-probes.lua), then states the loop
   completion candidate, accepted alias rule and implementation discrepancy.
   Sections 6/8 tighten construction ownership using the
   [call-site retention probe](construction-probe.lua) and retain the withdrawn M1
   scope proposal as history, not an agreed core-design boundary.
   Section 9 records the retry review, [earlier mechanism probes](retry-probes.lua) and
   [ownership countermodels](retry-owner-probes.lua).
2. [Storage derivation](storage-derivation.md): Goose's invariants versus Nua's
   extensions; the two-live-owner witness; symbolic placement and Nua realization;
   borrowing, recursion and construction ownership; [observations](storage-probe.lua)
   and the history of the now-resolved no-copy boundary. Its representation sketches
   are not mandates for a larger allocation engine.
3. [Representations](representations.md): current kinds, payloads, identities,
   edges and phase invariants; source crosswalks, not mandatory replacement kinds.
4. [Operations](operations.md): primary results, effects, traversal policies,
   candidate passes and explicit default behavior.
5. [State and boundaries](state-and-boundaries.md): creators, roles, lifetimes,
   sharing, completion, undo and cross-attempt evidence.
6. [Scenarios and freeze review](review.md): concrete success/rejection paths,
   evidence, revised recommendations and the freeze checklist.

Use these inventories to challenge implementation of the approved semantic core, not to reinstate the withdrawn scalar-only milestone. The loop-alias rule (W02) and complete region/completion/task mechanisms are approved. Concrete APIs/layouts and kernel correctness still require implementation; older D01–D06 recommendations must be read against the subsequent architecture, not treated as overriding decisions.

[Syntax](../../syntax.md) owns language/ABI contracts;
[architecture](../../architecture.md) owns compiler/runtime contracts. In a conflict,
record the discrepancy: an old branch or comment is not a new language rule.
The method is Mua's [Writing compilers][guide] and
[Designing and writing Mua][design], both reread in full for revision 3.
Their examples guide the method, not Nua's native semantics; derivation §9 records
where adaptation is needed rather than silently treating a departure as guidance.

Notation throughout:

- **Observed**: current source behavior, not necessarily the intended contract.
- **Required**: an existing language/project contract or the user's stated model.
- **Recommended**: a replacement-design choice awaiting review.
- **Approved**: an explicitly accepted rule or design choice, not proof of implementation.
- IDs `R`, `O`, `S`, `B`, `W`, `D`, `G` name representations, operations, state,
  boundaries, witnesses, decisions and gaps. They are document IDs, not proposed
  code names. Source symbols retain their current abbreviations for navigation.

## What the guide requires, adapted to Nua

| Guide obligation | Inventory answer |
|---|---|
| Pipeline and inspectable intermediate data (§1) | R01–R18, including unfinished versus prepared residual work; closures remain explicit opaque host inputs |
| Closed kinds and checked fields (§3) | R03, R06–R10, R12–R14; non-family objects and open extension vocabularies are distinguished |
| Result and effects for each operation (§4.2) | O01–O45; no assumption that a query-looking name is pure |
| Coverage and composition (§4.4) | Operation domains and explicit leaf/identity/rejection policies; no unknown-kind fallback |
| State by role and boundary (§4.5) | S01–S27 and B01–B14; path rollback is not whole-function rebuild |
| Invariants of intermediate forms (§9.1) | Representation phase rules and boundary postconditions |
| Output ownership and ordered rewriting (§10) | Construction owner, predecessor patching, sealed output and analysis invalidation |
| Debug printing, comparisons, tests (§§6.3, 10.6, 12) | O42–O45 and W01–W12, including failures and state obligations |
| Activities, outcomes, lifecycle (design guide Part I) | Explicit setup/completion/rejection, signal destinations, construction lifecycles and edge responsibilities |

This is not a plan to transplant the guide's parser, Lisp interpreter or register
IR. Mua already parses Nua. Native arithmetic has target-width rules; ordinary
Lua arithmetic is not its reference oracle. Delayed Lua bodies are not finite
syntax trees that a family pass must replace. Arbitrary Lua captures cannot be
printed and read back as a complete compiler heap: inspect their identity and
provenance instead.

## Scope and coverage ledger

The freeze concerns **semantic responsibilities and representation/state
contracts**, not file splits, exact signatures or a line-for-line port. A helper
is covered by the operation it implements; the operation inventory is not a
second function index. Adding a capability after freeze requires updating its
representation, operations, boundary and witness together.

| Source area | Responsibility and inventory coverage |
|---|---|
| `nua.lua`, `nua/loader.lua`, `nua/application.lua`, `nua/front.lua` | Composition, module lifetime, Mua host, application proof, generated staged closures: R01–R05, O01–O06, S01–S05 |
| `nua/types.lua`, `nua/fold.lua`, `nua/array_value.lua` | Native identity, numeric meaning and persistent sparse array contents: R03/R06, O07–O10 |
| `nua/stage.lua` | Application/evaluation/residualization/materialization and compiler primitives: R04–R17, O04–O30, S04–S21 |
| `nua/memory.lua` | Library owner declarations, placement, moves, releases and evaluation integration: R13–R15, O18–O22, S12–S18 |
| `nua/strings.lua` | Known-text representation and bindings to Nua words; host conversion edges: R06, O08/O09/O30, S02 |
| `nua/cgen.lua`, `nua/layout.lua`, `nua/task_globals.lua` | Shared graph preparation plus C lowering: R09/R10/R15/R16, O31–O38, S22–S25 |
| `nua/jitgen.lua`, `nua/cjit.lua`, `nua/gccjit_h.lua`, `nua/probe.lua` | Same prepared input; C ABI/type/CFG adapter, header facts and gccjit handles: R18, O38–O40, S25/S26 |
| `nua/native.lua`, `nua/runtime_build.lua`, `nua/toolchain.lua` | Result lifetime, runtime artifact and external tool edges: R18, O40/O41, S26/S27 |
| `nua/size.lua` | Attribution and measurement-only call policies: O43, S20; not normal language semantics |
| `nua/fmt.lua`, `nua/fmt_cli.lua`, `nua/project.lua` | Adjacent tooling; preserve application-proof/configuration interfaces. The parked formatter-style change is not part of this rewrite |
| `nua/direct.lua`, `nua/direct/*` | Explicitly experimental/deprecated backend; prepared-IR consumer, retained artifacts and limitations. No removal or production-equivalence promise |
| `lib/*.nua`, `runtime/*.nua`, runtime C/platform code | Nua algorithms remain Nua; boundary vocabulary, layouts, task/wait contracts and minimal platform mechanisms remain obligations, not material to migrate into Mua |
| `tools/`, `tests/`, `examples/` | Build/package/test consumers and witnesses; no new build system or broad validation campaign proposed |

The C reader in `cjit.lua` is a backend-local compiler, not a second Nua front
end. R18 inventories its domains and interface. Freezing this core rewrite does
not authorize rewriting that reader, the direct backend's assembler or platform
mechanisms without their own detailed migration review. Their input/output and
lifetime obligations are included; claiming every internal backend field has been
audited would be false.

## Curation and freeze rule

A row is useful only if it answers a design question. Keep source spellings as
crosswalks, not as the replacement's vocabulary. Separate structural children,
identity references and mutable attachments. When source evidence changes, update
the relevant row and its witness, not just this index.

A freeze means:

- the four responsibilities and their observable contracts are agreed;
- every core representation and operation has a disposition;
- every state category has a creator, validity boundary and completion owner;
- intended memory semantics constrain the core, including features implemented
  later; discrepancies are resolved or explicitly recorded with their design
  obligations, not hidden by implementation exclusions or compatibility paths;
- review decisions D01–D06 and gaps G01–G04 have dispositions;
- the user approves the inventory revision before implementation begins.

The [review page](review.md) records what currently prevents that declaration.
Inventory completeness is not correctness evidence for a rewrite that does not
yet exist. A later implementation finding can reopen a frozen item explicitly;
“frozen” does not mean silently forcing the code to fit a mistaken premise.

[guide]: https://github.com/cperion/mua/blob/f74545c99f429da4bfe169d32012e6f62e6bf367/docs/writing-compilers.md
[design]: https://github.com/cperion/mua/blob/f74545c99f429da4bfe169d32012e6f62e6bf367/docs/designing-and-writing-mua.md
