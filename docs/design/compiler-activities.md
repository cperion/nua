# One evaluation system: program IR and compiler activities

**Design commitment, not an implementation-completion claim.** After reviewing
Mua's compiler guide, the user asked to replace further inventories with explicit
IRs and activities, required symbolic execution and residualization to be **one
system**, and said “lets expand and commit to that”. This document expands that
accepted direction. It does not revive the withdrawn scalar-only milestone, add
language exclusions, or claim the current compiler already has these structures.

[Syntax](../syntax.md) owns language/ABI contracts; [architecture](../architecture.md)
describes the compiler/runtime boundary and current implementation. This is the
replacement design, not an inventory of current fields and tags. Earlier research
remains evidence and coverage questions, not a blueprint or an implementation.

## 1. Commitments

> Supply what you know. Evaluate in place. Keep what remains. Share with `call`.

1. **Symbolic execution and residualization are one evaluation activity.** The
   same operation handlers compute with available information, change semantic
   state, and produce required residual work. There is no preliminary interpreter
   followed by an independent implementation that emits the program.
2. **Use Mua's AST, not another source tree.** Retain Nua's Mua host and staged
   word bodies as the starting substrate. Host values, closures and generators
   remain available; hosting is not a translation to Lua followed by reparsing.
3. **Use one Nua program IR.** Checking, collecting, rewriting, placement and
   storage realization are operations over it. A new pass does not imply a new
   wire type. A genuinely different representation must earn its existence.
4. **Choose explicit control-flow blocks, immutable computed values and mutable
   places.** Definition and block identities are separate from source word and
   invocation identities. Normal application does not create a native function.
5. **Keep state with the activity that owns it.** Handlers may capture it or
   receive it. No universal context, transaction, dependency-repair or state-machine
   framework is selected by this design.
6. **Make memory semantics part of evaluation.** Preserve stable/shared-position
   guarantees, borrow origins, ownership and cleanup obligations before assigning
   final physical storage. These are not backend discoveries.
7. **Keep algorithms in Nua.** Storage realization evaluates Nua storage words
   through the same system. Growth, copying, compaction and cleanup do not become
   separate Lua/C algorithms or backend-specific semantics.
8. **Publish only at explicit completion boundaries.** Rewrites own new output;
   consumers do not mutate a completed producer's construction state. Mutually
   revising work belongs to an explicitly owned activity over the same program.

The method comes from [Writing compilers in Mua][compiler-guide]: closed families
and open operations (§§1, 3–4), primary results and effects (§4.2), state ownership
at boundaries (§4.5), stateful vocabulary factories (§4.6), owned rewrites (§10.1)
and cooperating passes over one instruction family (§10.6). The guide's roles are
questions, not a framework (§17). Its bounded optimizer may stop early because
unfinished optimization leaves correct code; unfinished ownership or placement
cannot use that excuse to publish an executable program.

## 2. Representations and wire contracts

```text
Mua AST / hosted source
        |
        | hosting and evaluation use one semantic operation system
        v
Nua program IR
        |
        | analyses and rewrites; some activities coordinate repeated work
        v
Nua program IR satisfying backend-ready invariants
        |
        +--------------------+
        v                    v
      C text          libgccjit construction
```

An arrow names a transformation and its input/output contract. It does not require
pure handlers, a different family, or a single traversal. Analysis facts and
placement assignments are named data products, but are not additional program IRs.
Feedback inside an activity revises that activity's owned work, not a supposedly
finished upstream representation. Hosting may invoke evaluation while the host
program runs; it need not first collect every word into a closed whole-program IR.

### 2.1 Semantic objects, not extra pipeline stages

| Object | Meaning |
|---|---|
| Word | Computation identity, requirements, supplied bindings and hosted body |
| Application | Supplies arguments; incomplete supply does not run the body |
| Invocation | One evaluation lifetime with its local bindings, exits and owned work |
| Staged value | A native value described with available knowledge, or a host value where the language permits one |
| Place | Stable source-visible identity whose contents may change |
| Holding | Which lifetime currently owns an allocation and its cleanup |
| Definition | A materialized native boundary with parameters, code and a derived contract |

Native staged values have native types. Scalar contents may be known or name an
immutable residual result. Records, arrays and sums may have independently known
components; a single whole-value known/dynamic flag is insufficient. References
carry target/origin and storage-guarantee information. Owners denote holdings,
not freely duplicable headers. Host tables and closures need not belong to one
universal family with native values.

A word body may be an opaque Lua closure. Inspection records its identity, source
and supplied bindings; it does not pretend arbitrary Lua captures are serializable
IR. Knownness determines binding time, not a different set of native semantics.

### 2.2 Program shape

```text
Program
    definitions, globals, exports

Definition
    identity, parameters, boundary contract, entry block, blocks

Block
    identity, arguments, ordered instructions, terminator

Edge
    target block, supplied arguments
```

These are conceptual checked shapes, not final constructor signatures. Program
identities are explicit references; visitors do not recursively traverse arbitrary
Lua tables. Definitions exist for requested/required native boundaries, including
exports, shared calls, recursion and task execution—not for every applied word.

An instruction result is defined once. Block arguments merge values from incoming
edges. Mutable-place contents remain an evolving semantic fact, with explicit
loads/stores when runtime storage is necessary. This does not force every local
into memory or make known contents dynamic.

Ownership is not inferred from copying a value ID. An aggregate containing owners
is not freely duplicable merely because its computed header has an immutable
name. Transfers and the corresponding edge/lifetime obligations remain explicit.

### 2.3 Constituent families

Several closed families can describe one program representation:

| Family | Shapes and obligations |
|---|---|
| Operands | Typed constant, definition parameter, block argument, instruction result |
| Places | Local, field, checked element, reference-target access, explicit foreign-memory access |
| Instructions | Computation; load/store; address exposure; invocation; checks; ownership/storage transitions; required atomic/task mechanisms |
| Terminators | Jump, conditional branch, return, trap, suspension with a continuation |

These are kind groups to specify while building the first example, not an unchecked
`Operation { anything }` payload. Operator sets, operand/result types, effects,
identity edges and source provenance need checked contracts. Every pass covers its
family explicitly, including identity/no-contribution handlers where appropriate.
There is no default handler that quietly accepts unknown kinds.

Arithmetic, conversion and comparison use target-native validity and width rules.
Loads, calls, atomics, checks and suspension are execution sites, not expressions
that may be moved merely because a visitor calls them pure. Expressions may be
inlined by a later rewrite only when effects, validity, observation and dominance
permit it. Evaluating operands is ordered; a multiple assignment does not silently
choose the traversal order of effectful handlers.

### 2.4 Storage and reference facts

The program names logical allocations and semantic ownership operations:

```text
begin owned storage
transfer a holding
end a holding
access initialized contents
```

Logical ending is not necessarily an immediate physical rewind. Reclamation may
be retained by a larger result region or shared arena. A move transfers cleanup
responsibility as well as the selected header. A reference records possible origins,
lifetime dependencies and stable/shared-position guarantees; none may disappear
when its native pointer is materialized, stored, selected or returned.

Facts may be carried by checked descriptors/maps keyed by program identities; they
need not be repeated in every node. They must belong to the representation or an
explicit boundary contract, rather than to accidentally reachable builder objects.
A lifetime bound alone does not prove exact target or allocation identity.

Memory choices already made for this redesign remain inputs:

- stack-backed ownership, no general heap, GC or reference counting;
- stable standalone storage and potentially relocating shared-position arenas;
- one safe initialized typed-buffer foundation, composed by Nua containers;
- no requirement that container authors use raw pointers or manual retirement;
- ordinary moves/returns transfer storage without copying contents;
- crossing storage positions, including insertion of a call result, may relocate
  contents; automatic direct construction is an optimization, not correctness;
- construction activities initialize/publish an element and then lend it; callback
  return does not imply rollback or atomic publication;
- aliases remain allowed; no new exclusive-borrow system is introduced.

Slots reused later do not revive earlier borrows. A view whose pointer/length were
captured still requires live contents. Independently moving owner fields must not
allow one field's cleanup to reclaim storage another still needs. These rules apply
to loops, recursion, sums, globals, tasks and foreign boundaries; implementation
order does not turn an intended feature into a forbidden program.

### 2.5 Readiness, not another IR per pass

| Condition | What it promises |
|---|---|
| Private construction | Its activity owns open blocks, pending definitions, path facts and reconsideration; this is not executable output |
| Semantically complete program | Native types, uses, control and boundary contracts are established; source-level ownership/borrow obligations are satisfied; outstanding physical storage constraints are explicit |
| Backend-ready program | All reachable definitions and targets are closed; physical storage operands are resolved; required transfers, captures and cleanup are executable; storage-ordering proofs hold; no unresolved logical operation remains |

The latter two are checked conditions over the same program family, not two copies
of all its types. An unsatisfied physical constraint prevents backend readiness;
semantic completeness alone is not acceptance of an executable layout. A rewrite
that invalidates a condition must say so and re-establish it before publication.

## 3. One symbolic-execution and residualization activity

The conceptual handler contract is:

```text
handle(native operation, evaluation state)
    returns: a staged result, where the operation has one
    changes: semantic facts and activity-owned residual output
```

All binding times use these handlers. There is no “unknown operand” fallback to a
second compiler, no preliminary execution to discover results followed by another
execution to emit them, and no second implementation for Nua storage helpers.
Necessary reconsideration replaces owned facts and residual output together.

| Operation | Integrated behavior |
|---|---|
| Arithmetic | Compute when available operands and native validity permit; otherwise emit the required computation and return its symbolic result |
| Read | Return valid tracked contents or produce an ordered observation; its result is an immutable value, not a recipe that later reads changed contents |
| Write | Update place contents and ownership/borrow facts; establish runtime storage where required, preserving lazy stores |
| Conditional | Select one known arm; otherwise evaluate both under separate path facts, emit control flow and reconcile live predecessors |
| Loop | Execute accepted known rounds; establish a reusable residual header and edges when necessary, using the same operation handlers |
| Ordinary application | Bind supply without execution until saturation; then evaluate in the caller's circumstances without a native boundary by default |
| Explicit `call` | In a residual context, request a shared specialization using supplied knowledge; in host compile-time evaluation, retain the specified in-place behavior |
| Ownership/storage | Check lifetime and storage guarantees as the operation happens and produce its required runtime work; owner creation remains runtime storage |
| Trap | End the current native path; do not fabricate a return value or a caller continuation |

**Known result is not the same as no residual work.** A mutation, check, call or
atomic operation may have a known or unused result and still require an execution
site. Sharing a definition is not permission to skip repeated invocations or their
effects. General known-result memoization is not part of this starting design.

An earlier read of a tracked place keeps the value observed then. Address exposure
can require a store before the exposing operation and loss of private knowledge;
it does not retroactively change the earlier value. Direct access and references
to a carried local observe that same place in known and residual loop rounds.
Earlier scalar observations, distinct copies, by-value arguments and task captures
retain their different meanings.

### 3.1 State by role

| Role | In evaluation | Boundary treatment |
|---|---|---|
| Inherited | Lexical bindings, available supplies, enclosing identities | Extend bindings for nested work; do not overwrite the parent's bindings |
| Accumulated | Diagnostics and contributions to owned definition/region requirements | Share only within the owner whose completion includes those contributions |
| Evolving | Contents knowledge, holdings, loan validity and current flow | Fork for residual paths; reconcile at their actual continuation |
| Produced | Values/blocks and provisional definition work | Own locally; adopt together on success; discard together on rejection |
| Capabilities | Fresh identities, module resolution, explicitly supplied host facilities | Share intentionally; a capability is not a bag of all compiler state |

Capture what belongs to the activity; pass what changes within it. A factory makes
fresh handlers/state for independent work. Spreading handlers copies closures, not
their captures. Nested rewrites receive their own output, never replace a caller's
output field. Native construction discard does not undo arbitrary Lua effects or
complete host resources; those resources retain explicit completion owners.

## 4. Activity contracts

The following activities are responsibilities, not a prescribed module per row.
Their state machines describe owned work, not a universal outcome/driver framework.
A source-contract violation produces a diagnostic and abandons the affected
construction; it is not successful completion with a dummy value. Actual host
errors/resources follow their explicit completion rules. These common obligations
do not require every activity to use one generic outcome type.

### 4.1 Compile a program

**Input:** source/module entries and requested output. **Result:** inspected program
representations, diagnostics and requested backend products. **Owns:** module-loading
lifetime, definition registry, diagnostic accumulation and identity capabilities.

It hosts Mua source and connects evaluation, preparation and emission. Existing
stable host/type identities may be shared deliberately; invocation facts and new
program modules cannot leak into another compilation. It returns completed output
or a diagnostic and completes its actual host resources. It does not inject a
universal compilation context into every operation handler.

### 4.2 Evaluate an invocation

**Input:** word, saturated supply, lexical bindings and current path circumstances.
**Primary result:** staged result or terminating/control outcome. **Effects:** native
mutation facts, lifetime transitions, residual output and definition requests.
**Owns:** local bindings, observations, local lifetimes and tentative output.

```text
evaluating → returned
evaluating → terminated
evaluating → requires reconsideration → evaluating owned work again
```

Partial supply precedes invocation; it does not enter this machine. Nested ordinary
application uses the caller's path facts, not a cloned native allocation world.
Returning supplies its actual continuation; terminating does not. Body return,
parent adoption and publication are different boundaries. An accepted child is
still tentative under its parent; rejection drops its contributions as well.
Accepted prefixes/siblings are not discarded merely because later work changes.

### 4.3 Construct a control region

**Input:** entry facts, participating places and target continuations. **Result:**
blocks and facts for each surviving continuation. **Owns:** predecessor results,
header assumptions, continuing/exiting sites, edge transfers and cleanup.

Branch construction forks facts and joins live predecessors; no live predecessor
may be treated as initialized merely because another is. Reference joins preserve
origins and guarantees, not just pointer bits. A loop's core transitions are:

```text
establish header → evaluate body → check continuing edges
                                     ├─ holds → complete
                                     └─ weakens → reconsider owned body
```

Discovering a participant is not by itself proof that a header assumption failed.
A write restored before a continuing edge may preserve the assumption. Exit-only
changes establish exit facts, not automatically weaker next-round facts. Inner
exits are not outer back edges. Edge inputs are captured before assignment or
invalidating cleanup, preserving simultaneous updates and ownership transfers.
This is nested evaluation, not a second interpreter or a second loop IR.

### 4.4 Construct a shared definition

**Input:** word and specialization inputs, including relevant reference/storage
guarantees. **Result:** definition and boundary-relative contract. **Owns:** fresh
parameter-relative evaluation, return origins, recursive dependencies, move and
borrow effects. It invokes the same evaluation handlers as ordinary application.

```text
requested → building → awaiting recursive agreement → complete
```

Recursive calls may refer to a definition being built. Callback return alone does
not close a recursive group's assumptions. If a newly discovered move or borrow
effect changes dependent evaluation, the owning construction coordinates that
reconsideration before publishing. This is semantic feedback, not stack numbering.
A call site belongs to its caller's output; retaining a definition does not retain
discarded caller operands. Definition contracts cannot contain caller-local places.

Residual `call` still specializes known supply and requests shared residual work,
even where its result is known. Specialization keys do not use absolute stack
indices or arbitrary lifetime-token identities. No new retry transport is selected
here: the current targeted transport has no demonstrated need for replacement.

### 4.5 Analyze and realize storage

**Input/output:** the same program IR family. **Result:** a rewritten program with
executable storage work and established readiness. **Owns:** working program output,
allocation/order constraints, result-region requirements, assignments and pending
Nua realizations. Analyses produce explicit facts; they do not mutate an earlier
producer's private builder or require another copy of the program vocabulary.

```text
collect requirements → assign storage → realize operations → verify
          ^                                  |
          └──── new requirements in owned work ┘
```

This is one activity when those operations can affect each other. Its driver
coordinates their handlers over the same work. It is not a sequence of supposedly
finished checking/placement/lowering IRs with hidden backward requests.

A logical allocation may occur once per accepted known round, or repeatedly at one
residual loop site. Source location or the nth allocation in two attempts is not
proof of identity. Rejected construction contributes no placement evidence unless
a separately justified contract explicitly retains it.

Nua storage words run through the same evaluator with the available type, mode and
layout inputs. Their generated definitions/allocations, if any, belong to this
activity's work and must be included in its completion. Their realization must
preserve the original operation's semantic contract: it cannot revive loans,
weaken source guarantees, reorder effects or replay arbitrary user computation.
A numeric placement change alone does not restart source evaluation.

Completion requires resolved operands, valid growth ordering, adequate result
regions, correctly placed pre-call captures, and cleanup that cannot reclaim live
storage. A larger reclamation extent travels with the appropriate ownership;
partial moves may not prematurely release it. The activity cannot stop at an
iteration cap and emit unresolved work. The convergence argument and exact region
realization are implementation obligations, not already proved by this diagram.

### 4.6 Rewrite a program

**Input/output:** the same family. **Primary handler result:** replacement nodes or
blocks. **Effects:** the rewrite's specified facts/output only. **Owns:** new output
and its analysis state; nested rewrites have independent output lifetimes.

Identity, collection and rewriting handlers compose as in the Mua guide. Input
nodes may be shared with output only while they remain unmodified; a rewrite does
not alter an earlier inspected result through shared mutable attachments. One
rewrite can enable another; a driver may repeat them on this representation.
Structural/semantic change, not merely instruction count, determines convergence.
Optional optimization may stop with a valid less-optimized result. A change to
calls, control, ownership or lifetimes invalidates the affected placement facts;
backend readiness must then be re-established. No obsolete plan remains attached
as if it still proved the new program.

### 4.7 Emit a backend

**Input:** a backend-ready program. **Result:** C text or libgccjit construction.
**Owns:** backend names, declarations, labels, output and backend resources.

It translates already established execution. It does not infer ownership, choose
container algorithms, repair cleanup or implement another borrow system. Both
backends consume the same prepared view. Backend readiness is verified, not assumed
because a previous helper returned successfully.

### 4.8 Inspect and verify

Printers, invariant checkers, collectors and decision explanations are ordinary
operations over the families. A printer is implemented with the first kinds, not
added after the compiler becomes opaque. Inspect the activity's state separately
from its produced program; do not serialize a retained compiler heap as IR.

Verification checks constructor shapes plus graph/type/dominance/lifetime and
readiness obligations as applicable. Repeating and nesting activities must not
change an earlier independent result. Identity references and deliberate sharing
need explicit comparison rules; unrestricted recursive table equality is not an
allocation or provenance proof.

## 5. Worked traces that fix the interfaces

### 5.1 Same word, different knowledge, same handlers

```lua
local affine = do(scale: U32, bias: U32, x: U32): U32 = scale * x + bias
local transform = affine 4 3
```

| Supply/context | Evaluation and residual result |
|---|---|
| Bind `affine 4 3` | Partial word; body has not executed |
| `transform 5` | Native arithmetic yields known 23; no residual arithmetic is needed |
| `transform x`, runtime `x` | Same arithmetic handlers produce multiply/add results with constants 4 and 3; no call boundary is introduced |
| `call transform x`, residual context | A shared definition specializes scale/bias; its runtime parameter is `x`; caller produces an invocation |
| Known arithmetic after an effect | Arithmetic may disappear; the required effect does not disappear with it |

A known-component record follows the same rule field by field. This is not
whole-word knownness or a separate dynamic implementation.

### 5.2 A place and its earlier observation

A place `p` contains value `v0`. Reading it binds `before = v0`. A later write gives
`p` contents `v1`; direct and aliased access now observe `v1`, while `before` still
means `v0`. If a runtime read was needed, its result ID fixes that observation.
If an address becomes exposed, establish the required contents at the exposure
site. Neither a late store nor storage placement may turn `before` into a read of
`v1`. If the bound value was a view, preserving its bits does not waive loan validity.

### 5.3 Two owners, a result and a container

This is a semantic sketch, not final IR constructor syntax:

```text
begin A
begin B
... evaluate ordinary Nua work that grows both ...
branch flag
    true:  capture/transfer A to result; end B; return result
    false: capture/transfer B to result; end A; return result
```

A and B coexist and need distinct growing storage. Known control selects one
return path, not permission to omit earlier effects. Inline returns transfer into
the invocation's continuation. Shared evaluation produces a definition with both
possible origins; it does not start another semantic engine.

Storage realization assigns compatible positions and reclamation work from these
facts. A caller may then relocate the selected contents into its container's
storage. Alternatively, an initialized element can be lent to the same ordinary
Nua writer and filled there. Neither form changes the shared-position borrow rule.

Recursive forwarding keeps the returned holding alive through intermediate levels.
Recursive combination may retain consumed bytes below a later result until the
outer region is reclaimed. A mixed argument/fresh result must transfer the correct
cleanup on either edge. Those cases challenge the same representation and activity,
not separate recursive, container or cleanup engines.

## 6. What is committed, and what still needs implementation proof

The design decisions in §§1–4 are the direction to implement. Exact constructor
names, handler signatures beyond their result/effect contracts, scheduling details
and file splits are not frozen by this document. In particular:

- The reference contract must be worked through known targets, joins, materialized
  pointers, aggregate fields and native boundaries. A potentially shared target
  cannot become stable because its original place representation was lost.
- Loop and recursive completion need a precise agreement/reconsideration driver;
  no assumption that a different retry transport is necessary has been adopted.
- Storage realization needs a concrete finite dependency/convergence argument and
  an ownership-safe treatment of mixed origins and independently moved fields.
- Task capture, suspension, foreign access and safe library storage must participate
  in the same contracts, even when their implementation follows incrementally.

The next artifact is a small end-to-end construction using the first checked
shapes, handlers and activity states—not another exhaustive inventory or a port
of the current tag tables. Walk the traces above through staged values, program
output, ownership facts and storage completion. Print every intermediate result.
Then add the recursive, reference-result and partial-move cases before calling the
boundaries complete. Temporary implementation gaps are not language exclusions;
there is no hidden fallback to the old evaluator in a replacement path.

This design commit adds no compiler implementation and claims no new executable
acceptance results. Its checks are documentation/contract consistency. Later
focused tests must distinguish staged success, correct rejection, verified IR and
native behavior; two backends sharing erroneous IR are not independent semantic
oracles. Compile-heavy validation remains off unless separately requested.

[compiler-guide]: https://github.com/cperion/mua/blob/f74545c99f429da4bfe169d32012e6f62e6bf367/docs/writing-compilers.md
