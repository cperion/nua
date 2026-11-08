# Deriving the evaluator from Nua's problem

**Revision 5:** the user approved the overall [checked-storage design](../checked-storage.md),
including safe typed-buffer composition, cross-position result relocation and
late physical placement. It records focused implementation/evidence work and the
reference-result blocker. This does not revive the withdrawn scalar M1 or select
every representation and completion mechanism proposed below.

**Revision 4 history:** [storage derivation](storage-derivation.md) developed §4 from
Goose and Nua's stronger move/nesting/recursion contracts. Its six staging-only
observations remain evidence; its formerly open no-copy boundary is now resolved.

**Revision 3 history — proposed freeze withdrawn before compiler implementation.**
The user challenged deferring the memory model and freezing feature exclusions.
Sections 6/8 remain proposals, not an agreed replacement architecture. Memory
semantics must constrain the core even where implementation is incremental;
temporary unsupported diagnostics do not define new language restrictions.
`review.md` records the reopened decision.

**Earlier investigation status:** The
user approved continued problem-first investigation, a full guide reread and
focused retry-propagation experiments and their review, not the architectural
choices below. Revision 3 revisits retry ownership; its subsequent recommendation
for private unwind is withdrawn after review (§9), not frozen. The loop-alias
language rule in §3 is now user-approved; its construction design is still a
candidate, and the observed compiler discrepancy remains unfixed.
[Syntax](../../syntax.md) remains authoritative. Residual sketches are reasoning
exercises; §3 reports actual staging observations separately. The historical
observations below predate the small terminating-path correction recorded in the
checked-storage design. No compile-heavy tests accompany this work.

The inventories are a coverage check, not a blueprint. A distinction in the old
compiler earns a place in the replacement only when a semantic obligation or a
concrete engineering need justifies it. Conversely, fewer records or modules is
not a simplification if their hidden obligations become harder to explain.

## 1. The job, before the machinery

> Evaluate with the information available. Preserve the changes and obligations
> of that evaluation. Construct the native work that remains. Introduce a native
> function boundary only when requested or required.

Success includes binding time, residual shape and rejection, not just the final
number. In particular:

- Partial supply binds static arguments without executing the body. Saturation
  evaluates with **all** known inputs, normally in the caller's evaluation.
- Native types determine numeric meaning; knownness determines binding time.
  Aggregates can be partly known. Known contents need not be static/capturable.
- Native mutation can change pending contents without producing an instruction.
  Native effects that require runtime execution remain ordered runtime work.
- A known condition evaluates one arm. A dynamic condition evaluates alternatives
  with separate path knowledge. Unreachable continuations are not evaluated.
- Identity, earlier reads, ownership and borrowing must survive specialization.
  Raw-pointer memory does not become a general compile-time heap.
- `call` in residual evaluation requests a shared specialized function even when
  arguments are known. Host compile-time `call` still evaluates in place.
- Lua remains the host; Mua supplies the existing AST hosting surface. Expressible
  library algorithms remain Nua words, not new compiler algorithms.

**Three different observations:** what value an invocation produces, what it
changes while evaluating, and what runtime work it produces. None determines the
other two. This is the central reason G03/G04's result-cache shortcuts are wrong.

## 2. First problem: a branch changes a local

Schematic Nua:

```text
local choose = do(flag: Bool): U32
    local amount = U32 10
    if flag then amount = 20 end
    return amount + 1
end
```

Known `flag`: evaluate the selected arm and obtain known 11 or 21. No native
function is created merely by applying `choose` in place.

Dynamic `flag`, within an existing native destination:

```text
                     one identity P for amount
entry                P has pending U32 10; no store required yet
true predecessor     P has pending U32 20
false predecessor    P has pending U32 10
continuation         the two contents disagree
edge completion      true stores 20 to P; false stores 10 to P
after join           read P's established contents; add U32 1
```

The predecessors must establish their own values. A single store after the join
cannot choose which pending value was correct. Exact generated spelling is not
the contract; a correct later rewrite may reshape it.

This derives three necessities: **storage identity**, **path knowledge**, and
**reconciliation at a continuation**. It does not derive a new function, a copy
of the entire compiler, or a universal transaction.

Now write `call choose true` inside residual evaluation: it requests a shared
specialization returning 21, with no runtime `flag` parameter. An earlier ordinary
`choose true` must not erase that boundary. `call choose flag` with dynamic `flag`
instead gives the specialized function a Bool parameter. Both use the same body
evaluation rules; host compile-time application still needs no native boundary.

### Stress the same problem

- If all live paths agree, keep their agreed contents. A dead predecessor does
  not poison the live one. An uninitialized live predecessor prevents treating
  the continuation as initialized; a later read must reject unless initialized.
- Bind an earlier read, then write `P`: the earlier value must not become a read
  of the new contents. Pending immutable contents already provide the snapshot;
  storage reads need capture at the binding's proper point when necessary.
  Preserve lazy snapshots for tracked reads, immediate capture for untracked
  reads, and version/lifetime checks (syntax §5.5).
- Give `P` a reference alias: both paths still name `P`, not cloned locals.
- Join two references: making the selected reference runtime data can expose its
  target's address. Reconciliation must then establish that target's contents on
  every affected path too. A join is not just equality over two maps.
- Make this an inline word's early returns: returns meet at that invocation's
  continuation, not at the enclosing activity's completion. Match producers
  first reconcile payload/state, then handlers reconcile their results.

**Simplification:** branch fallthrough, inline return landings and immediate
matches reuse state-establishment rules. Their destinations and completion
responsibilities stay distinct. No universal continuation object is implied.
Dynamic short-circuiting can likewise stage its conditional right arm once and
finish that branch; expression-form shortening follows only when justified.
The current `stage.short` can stage the right arm and then evaluate it again on
its effectful route. Reusing owned arm output is a candidate simplification, not
an asserted new defect or a promise that all evaluator replay disappears.

## 3. Second problem: an alias changes a loop's state

Use `Counting`, `mixed_aliases`, `widening`, `nested_aliases` and `escape_inside`
in [loop_adoption.nua](../../../examples/loop_adoption.nua). Initially the record
has `count = 0`, `step = 3`; an alias calls `hit` inside a loop with dynamic bounds.

The question is not "which variables did the loop syntax list?" It is:

> What state must the next round receive, and which entry facts remain true
> after every continuing edge?

For `mixed_aliases`, direct mutation and `alias:hit` name the same record. The
round changes `count` by four; `step` stays three. The dynamic loop must carry
`count` while keeping `step` known. Giving the alias a separate round-local copy
breaks identity. Making every field dynamic needlessly loses specialization.

The current evaluator discovers hidden writes while executing the body, then
immediately requests adoption/escape and replays an enclosing loop. That is the
**observed strategy**, not a proof that discovery itself requires replay.
Separate four obligations before deciding how to implement them:

1. **Identity and participating state.** Under the adopted rule, direct access
   and aliases to a carried native local name the same original place in known
   and residual rounds. Discover which enclosing loops account for its contents;
   a nested loop can affect an outer loop too. The implementation gap is below.
2. **Repeated-entry facts.** Header knowledge must admit the initial incoming
   contents and every continuing edge. A fact true at each entry need not remain
   true throughout the body: a field may change and then be restored.
3. **Exit state.** Each exit establishes the contents/holdings required by the
   following continuation, including the zero-iteration path. An exit is not a
   continuing edge; disagreement among exits does not by itself invalidate a
   header invariant.
4. **Residual realization.** Establish initial carried state before the loop;
   capture incoming values before simultaneous assignments, including swaps.
   Keep address/lifetime requirements explicit. If specialization consumed an
   entry assumption that fails the continuing-edge check, revise that dependent
   work—by re-evaluation or another justified mechanism, not necessarily a
   universal discard-and-retry protocol.

In `widening`, a later conditional write to `step` defeats that invariant too.
In `escape_inside`, `call change alias` requires a real address and permits the
callee to change `step`. Establish storage **before** the affected loop and
stop treating that escaped record as private tracked contents. Reinitializing
it inside each round would erase earlier rounds' writes.

Known rounds that already completed are not failed attempts. Keep their work;
when a round becomes dynamic, reconsider that round under the loop rules
(syntax §6.2–6.4). Incompatible loop reference targets and changing scoped borrow
origins retain their rejection rules; no copying or heap promotion repairs them.

### What the existing evaluator actually does

[The evaluation trace](evaluation-trace.lua) stages ten small source programs
through the real front end/evaluator with `no_c = true`. It temporarily wraps
construction methods, records frame requests and rollback, then restores the
methods. These are **observations**, not acceptance criteria for the rewrite.
There is no preparation, runtime attachment, C emission or native compilation.

| Case | Known next rounds | Restart signals | Rollbacks | What distinguishes it |
|---|---:|---:|---:|---|
| `known_rounds` | 3 | 0 | 0 | Advances accepted computation; no retry |
| `mode_only` | 0 | 1 | 1 | Every argument was already dynamic; only inline → loop mode changes |
| `known_counter` | 0 | 1 | 1 | `k=0` was consumed as known; the loop needs dynamic `k` |
| `known_prefix` | 2 | 1 | 1 | Two accepted known rounds survive; reconsideration starts with `k=2` |
| `shared_recursion` | 0 | 0 | 1 | Completed inline output is replaced by a call to the shared recursive definition |
| `hidden_write` | 0 | 3 | 3 | Loop formation, discovery/adoption, then changed header facts are distinct restarts |
| `restored_alias` | 0 | 3 | 3 | State is adopted, but `count=0, step=3` remain known at the final header |
| `break_only` | 0 | 3 | 3 | Last restart widens `step`, though only an exiting path changes it |
| `address_escape` | 0 | 4 | 4 | Mode, adoption, escape and widening are separate steps; the shared callee survives |
| `earlier_read` | 0 | 3 | 3 | One tracked input is snapshotted before loop retries; its enclosing invocation survives |

`complete` in the trace means a construction method returned, not that its owner
accepted the output: `shared_recursion` completes and then rolls back. Attempt
counts include nested words and setup that may stop before the source body runs.
The printed suffix size counts only the saved block's attached statements, not
all privately constructed child blocks. A zero suffix does not mean no work ran.
The earlier-read trace does not establish the safety of retained attachments
(G01), and none of these counts demonstrates an equivalent retry-free compiler.

### Simplifications suggested by those distinctions

**Loop shape is not changed knowledge.** `mode_only` restarts with an empty
widening mask. For this capture-free scalar body, no known argument was invalidated.
A candidate invocation representation could keep dynamic-input bindings, exits
and a back edge unfinished until its owner decides whether to close a loop.
That may reuse the body instead of running it twice. It still owes argument
capture, dominance, lifetimes and simultaneous edge assignment; merely wrapping
old instructions in `loop` does not repair their parameter references.

**A write footprint is not a failed invariant.** In `restored_alias`, each round
increments `count` through a reference and then sets it back to zero. Only the
induction variable widens. The alias write revealed participating state; it did
not establish that `count=0` is invalid at the header. With original place identity,
try registering that participation without immediate replay, then compare contents
at continuing edges. Do not eagerly widen every written leaf: that would lose the
precision this example already has. Nested-loop registration and earlier read
bindings still need an explicit owner; this is a candidate, not an implemented fix.

**Exit disagreement belongs to exit reconciliation.** In `break_only`, all
continuing edges preserve `step=3`; one break path assigns `step=5`. Current
`S.loop_exit` compares the exit value with header arguments and requests widening.
`run_loop_body` subsequently joins `exit_states` by marking disagreeing contents
materialized; it does not run the ordinary predecessor-store reconciliation there.
Generalizing the field makes that storage assumption hold, but sacrifices a valid
header fact.

A smaller candidate is to preserve exit construction sites and establish each
predecessor's contents before the landing: `step=5` on that break, `step=3` on the
other exits, including zero iterations. This reuses the branch/return obligation
from §2 without weakening it. This must still satisfy syntax §6.4's **"Exits count
too"** contract: the post-loop value is dynamic and the required storage exists
on every exit. Keeping a header fact is not permission to keep the field constant
everywhere. This is a design argument for separating two joins, **not** a verified
replacement for the current loop-exit algorithm.

**Some specialization really has to be revisited.** `known_counter` initially
folds a return to `0`; the general loop must return its changing counter.
`hidden_write` initially selects the `count == 0` arm, but subsequent iterations
can require the other arm. Fixing stores or an address alone cannot recover
computation that eager evaluation omitted. Re-evaluation is a straightforward
candidate here; retaining dependencies/delayed computation or peeling a valid
specialized prefix are alternatives with their own costs and contracts. Nothing
in these traces proves that all such cases can be repaired without re-evaluation.

**Sharing and placement are separate decisions.** In `shared_recursion`,
`Builder:apply` discovers an already active specialization key and constructs the
shared function. After the initial inline evaluation completes, `run_frame` drops
that expansion and emits a call. The caller-side rollback is a boundary/sharing
choice, not evidence that its scalar facts became false. A representation owning
that expansion might discard it without restoring an entire evaluator snapshot;
keeping it would require review of sharing and boundary/lifetime behavior, not
just an assumption that more inlining is better.
Move-summary/result/arena rebuilds additionally change native contracts and graph
dependencies; the scalar experiments do not discharge those obligations.

### Candidate loop-completion contract

**Proposed, not frozen.** Start with ordinary scalar/record contents and stable
reference targets; this is not a new ownership, sum-tag or scoped-view widening
rule. The responsibilities interact during evaluation, not in four mandatory
passes. A possible loop needs only these distinctions to state its obligations:

- **Entry contents:** incoming arguments and recoverable facts about places at
  the start of this candidate round, after any accepted known prefix.
- **Header assumptions:** the facts used to specialize the reusable body. Entry
  contents initialize storage; weakened assumptions describe later entries. They
  are not interchangeable records.
- **Continuing and exiting sites:** each has its target, path contents, incoming
  values, lifetime obligations and unfinished predecessor output. A word return
  inside a loop is not an exit to the loop's following statement.
- **Owned construction:** body output, bindings and requirements stay tentative
  until these obligations are discharged. Child completion does not publish it.

**1. Keep inputs nameable before choosing the control shape.** A dynamic word
argument can have an invocation-owned input binding. If evaluation stays inline,
resolve it to the supplied value, respecting its original observation site. If
it becomes a loop, resolve it to a loop input initialized once from that value
and assigned at continuing edges. Its value is stable within a round, not across
rounds. This can avoid rerunning `mode_only`; it does not recover a branch omitted
using a known input. Stable references retain their target/provenance contract.

Input naming alone is insufficient for arbitrary bodies. Loop formation must
also validate any assumptions about lookup reuse, lifetime and repeated execution.
The current `run_loop` invalidates checked-lookup reuse on both sides; an inline
draft that used a non-repeatable caller lookup cannot simply be wrapped in a loop.
Keep such a dependency explicit or regenerate that work. The capture-free scalar
`mode_only` case does not establish this optimization for all applications.

**2. Discover participation without pretending a write is a failed invariant.**
An ordinary tracked write updates current path contents immediately. Register the
place with enclosing candidate loops whose entries contain it; recover its entry
contents from before the write, not from the new value. A place created within
an outer round can participate in an inner loop without being outer loop-carried
state. Previously completed paths that did not write it retain their entry facts;
absence from a newly discovered participant list does not mean uninitialized.

This requires recoverable entry facts—an entry-state reference or scoped before-
write records, not a universal context or a full state copy on every inline call.
The collection representation is not selected here. Registering with an enclosing
owner does not authorize mutating its surviving construction. Alias identity is
governed by the accepted same-place rule below, not repaired by inventing another place.

**3. Check repetition at continuing edges.** A known next round advances accepted
computation under §6.2; it does not need a fixed header or discarded output. A
residual back edge instead tests the header facts against its incoming contents.
For an ordinary known scalar leaf, keeping `known(c)` requires agreement with the
initial entry and every live continuing edge. Dynamic header inputs admit values
of the same native type, subject to reference/lifetime constraints; a header read
is not an immutable value shared by every runtime iteration.

If that check fails, the simplest candidate is to weaken the affected header and
re-evaluate its owning body. Do not add a dependency-repair graph or peel a runtime
prefix merely to avoid that evaluation. A first implementation can conservatively
regenerate on header weakening without proving which uses consumed the old fact.
This is a bounded construction rule, not proof that whole-program specialization
terminates. Native type, changing-host-argument and provenance refusals still hold.
Knownness may weaken monotonically at a header while assignments inside the body
establish new known values normally. Accepted earlier known rounds remain intact.

**4. Establish exits separately.** An exit contributes to its destination, not
to the header's continuing inputs. Retain its predecessor site so differing exit
contents can be stored before the transfer. Include the condition-false or skipped-
loop path at its actual enclosing join; numeric `for` can skip the loop entirely.
Capture incoming values before simultaneous assignments and before cleanup could
invalidate them; transfer holdings before releasing storage that must survive.
A landing with no live predecessors is unreachable, not an arbitrary joined
value; a separate skipped-loop path can still reach the enclosing continuation.

**5. Finish, then hand off.** Close loop shape, header inputs, predecessor stores,
read captures and lifetime/ownership obligations before publishing the body.
Keeping a known header field does not mean its storage always contains that value:
accepted operations and exits must establish whatever later observations require.
Closing an invocation without a back edge remains ordinary in-place evaluation,
not materialization of a native function.

### Nested loops: one place, different entry obligations

[The boundary probes](loop-boundary-probes.lua) add two real staging cases with
`state.count=0`, `state.step=3`, an outer `while i < n`, and an inner `while j < m`
whose body calls `alias:hit`. In one case the outer body then restores `count=0`.
The final successful loop constructions report:

| Case | Inner header | Outer header |
|---|---|---|
| `nested_keep` | `count=dynamic, step=3` | `count=dynamic, step=3` |
| `nested_restore` | `count=dynamic, step=3` | `count=0, step=3` |

These are observed header facts, not executed native results. Earlier completed
children in the trace can be discarded by a later enclosing restart.

Under the candidate contract, the inner owner checks its own continuing edges
and returns a completed exit state. That state enters the rest of the outer
body; it is **not** an outer back edge. The outer reset in `nested_restore` then
establishes zero. Without it, the outer header must weaken and any child built
under the discarded outer assumptions belongs to that discarded work too.
Likewise, a change confined to an inner `break` can invalidate an outer invariant
if the outer body carries it onward. Separate joins do not mean independent loops.

### Earlier reads and activities still have owners

An earlier binding `R = read(P, version, site)` names the value at its original
site, not the current loop input. Registering P or weakening its header must not
retarget R to a later read. Use §6's produced capture requirements: a child's
accepted requirement remains tentative under its parent; parent rejection drops
it, while requirements from an already accepted prefix survive. A write followed
by restoration can preserve a header invariant without cancelling an earlier-
read capture: the binding's intervening uses and version still matter.

For a write inside a Lua hook or lending activity, ordinary participation discovery
can return normally: current path contents were updated, not replaced with fake
operands under a pending-invalidity flag. The proposed header check happens at a
continuing edge. If the activity has ended before that edge, its normal completion
has already run. If an inner loop rebuilds while an enclosing loan is still live,
that loan remains owned by the enclosing activity; it must not be ended with the
inner draft. Loans born in discarded work do not leak into its replacement.

These are obligations, not an executed map/lending proof. `run_hook` and
`lib/map.nua`'s `storage.lend`, `lend_owner` and `methods.each` show the current
suppression, loan and iteration-state cleanup. Borrow validation remains immediate.
Moving a header check does not complete arbitrary host resources or solve G01's
surviving attachments.

Do not extend this completion rule to every discovery. Address exposure still
requires pre-loop initialization and the existing loss of private tracking; that
can weaken an enclosing construction's assumptions. Changed-known non-tail
recursion may need intervention before its caller returns to avoid endless
unfolding. Native summary/result placement retains its dependency domain (§4/§9).
Existing transport has no demonstrated defect, and replacing it is not a
prerequisite. No new unwind, coroutine or general retry framework is chosen here.

### Accepted loop-alias rule and implementation discrepancy

The other two boundary probes stage this pattern with known and dynamic `n`:

```text
state = Counting { count = 0, step = 3 }
alias = Ref state
total = U32 0
for i: U32 = 1, n do
    state.count = state.count + 1
    total = total + alias.count
end
return total
```

With `n=1` known, the evaluator writes `1` to a **round copy**, reads `0` through
the alias to the **original**, and produces a residual constant return of **0**.
With dynamic `n`, the completed residual loop writes and reads the **original**
place. No native execution was performed; the observed difference is in place
identity and staging, not a measured runtime result.

The previous syntax §6.4 wording described round copies, then original-place
adoption for alias-written residual state. `S.loop` still implements those copies;
`Builder:read` does not perform read-only-alias adoption. Eliminating their visible
effect is therefore a deliberate semantic correction, not just a relabelling of
the existing representation.

**Accepted language decision — user: "lets adopt that rule".** Direct access and
references to a carried native local observe the same current contents in known
and residual rounds. The required result here is **1**, not the observed **0**.
Syntax §6.4 now records this rule and the outstanding implementation discrepancy.
There is no separate isolated-round language mode, nor permission to make every
loop dynamic instead of preserving known evaluation.

Earlier bound values remain snapshots of their original reads. Distinct value
copies, by-value word arguments, task captures and lifetime rules are unchanged.
This approval settles place identity, not the physical storage representation,
re-evaluation protocol or the broader rewrite freeze. The existing probe and raw
observations are retained unchanged; the compiler has not yet been corrected.

## 4. Third problem: return ownership, not just bits

Consider two possible owner results, both live before the choice:

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

This must run within residual evaluation: creating owners is runtime-only even
with known inputs. `push` remains Nua computation, not an opaque host algorithm.

**Inline:** the caller keeps the result in its own place. Each return transfers
the selected owner's holdings to that destination. The unselected live owner is
released on that path; the selected storage must not be released by the old
holder as well. A result read must precede any cleanup that invalidates it.

**Materialized with `call`:** keep known inputs specialized. The caller supplies
result storage according to the native result protocol; the returned header
identifies the selected storage. The callee does not inherit the caller's entire
contents map. Its summary communicates relevant borrows, clears, moves and
storage obligations.

This disproves an attractive shortcut: **one logical result destination does not
mean one allocation for all possible results**. `left` and `right` coexist. They
cannot both be constructed in one interchangeable slot simply because one will
be returned. Existing result-stack planning can distinguish candidate allocations;
recursive result regions also have ordering/growth restrictions. Moving into a
container position has its own arena protocol and is not an ordinary local move.

**Simplification:** describe a move as transferring holdings and release duties,
not as a special sort of value copy. Share those obligations across assignment,
arguments and returns; let the destination/boundary determine placement.
[Revision 4](storage-derivation.md#4-candidate-describe-allocations-once-assign-their-stacks-later)
derives a candidate for describing allocations once and assigning their stacks
later. Semantic storage guarantees during evaluation do not imply physical
assignment there. The source already supplies dynamic stack-index operands;
result-region release generation and semantic feedback still need explicit
completion contracts, not a promise to eliminate every function rebuild.

Refusals are part of this example: use after move, returning a borrow of the
word's own local, exporting an owner result to C, and growing a recursive result
below another live result remain errors. See syntax §9.2–9.7/§9.13,
[errors.lua](../../../tests/errors.lua) and
[nested_owners.nua](../../../examples/nested_owners.nua).

## 5. The resulting core: responsibilities, not a module tree

```text
word + supplied arguments
    insufficient --> static partial word; no body execution
    saturated ----> evaluate in the current native situation
                        | known work computes
                        | path knowledge changes
                        | ordered residual work accumulates
                        | exits reconcile; lifetimes complete
                        ` reconsider only affected unfinished work

boundary requested/required --> specialize a native function with fresh evaluation
                              --> cross its parameter/result/effect contract

completed residual definitions --> exact-view preparation --> C or gccjit
```

The second route includes exports/native entry, explicit `call`, required
recursive boundaries and task entry with its additional capture protocol. It
uses the same evaluation semantics, not a second evaluator with weaker knownness.

| What needs an owner | Why it exists / when its work completes |
|---|---|
| Word and static supply | Stable computation identity; persists independently of any invocation |
| Current evaluation and invocation | Evolving path contents/holdings plus result, return and lifetime obligations; ordinary nested application operates in the caller |
| Unfinished construction attempt | Residual output, locals and patch obligations that may still be reconsidered; accepts or discards its work |
| Materialized specialization | A native boundary's identity, body, dependencies and summaries; recursive construction has explicit incomplete-summary rules |
| Preparation of an exact program view | Reachability, layout, storage and suspension proofs shared by backends; a different ABI/root view needs its own proof |

These are responsibilities, sometimes nested and sharing a lifetime, not five
mandatory structs. An ordinary inline invocation does **not** fork the caller's
path state or create a native body; its distinct responsibilities are arguments,
exits, lifetimes and any owned retry work. Fork where control actually branches,
and start fresh evaluation where a native boundary requires it. Do not copy a
large state record per operation merely to make each operation look pure.
Storage identities and native type identities are referenced, not copied with
each path. Native borrowing and ownership of compiler objects
are different problems; neither should be disguised as the other's token system.

### Share definitions, not ordinary evaluation results

Recommend **no general known-result memo in the rewrite's initial evaluator**.
Repeated application must repeat its semantic state changes. Primitive folding,
type interning and sharing materialized specialization definitions remain; each
has a different validity rule. Reusing checked lookups is also separate, scoped
to the path/epoch and invalidating events that justify it.

This removes a nonessential proof problem rather than designing a purity system
around G04. It also removes one way to bypass `call` (G03), though application
still has to honor boundary requests explicitly. It may cost compilation time;
measure later, then justify a narrowly scoped optimization if needed. A cache
hit count is not evidence that evaluating a word can safely be skipped.

### Put execution at named, ordered sites

Recommend a narrower invariant than "all expressions are pure": **calls,
atomics, checks and suspension are not freely nestable value recipes**. They
execute at explicit ordered sites, with optional captured results. Losing the
result's uses does not delete the execution (G02). This is a representation
proposal, not a change to source effect order or a new runtime mechanism.

| Computation | Proposed treatment / limit |
|---|---|
| `const`, `zero`, `null`, `param`, `agg`, `array`, `field`, `array_index`, `sum`, `tagname` | Value recipes when children meet the same rules and required checks are established; mutable loop parameters are stable only within the relevant round |
| `bin`, `cmp`, `un`, `conv`, `vaconv` | Native numeric/boolean and ABI rules; no blanket license to speculate, duplicate or move across control paths, especially for partial operations |
| `and`, `or` | Known-left selection or owned conditional right-arm evaluation; shorten to an expression only after establishing no skipped state/effects |
| `read` of tracked storage | Pending values can fold; deferred reads retain owned binding/version obligations until captured or proven valid at use |
| `read` of untracked storage / foreign variable | Observe at its required point and capture; not a constant or a freely reusable memory expression |
| `addr` / checked place | First perform evaluator escape/materialization and required lookup/check work; the resulting address still has identity/lifetime dependencies |
| `call`, `calli`, `rtcall`, `atomic`, `slot_at` | Ordered operation with a result if needed; explicit `call` boundaries survive unused results |
| `task`, `ops`, `block_fn`, `block_env`; waits | Respect the owning task/wait and suspension boundaries; no standalone universally stable placeholder |
| `fnaddr`, `gaddr`, `stack_index`, `res_index`, `sizeof`, `cconst` | Preserve identity or exact preparation/ABI dependencies; not runtime effects merely because metadata resolves later |

Stores, captures, fences, traps, stack restoration, spawn/wait and control
transfers remain commands with explicit ordering and completion. Calls consume
already evaluated arguments; address operands cannot hide an unperformed check.
Construction-only read bindings and patch points must resolve before publication.
The consumer-only spellings in R09/R10 do not become replacement kinds by default.
Arithmetic keeps existing UB/diagnostic rules: this is not a proposal to add
runtime arithmetic guards or new traps.

This does not eliminate analysis: read/write dependencies, trapping behavior and
legal movement still matter. It removes the need to rediscover effectful calls
hidden in arbitrary expression trees. Backend syntax can still use a C expression
at an ordered site. Do not introduce SSA, effect tokens or a new IR per operation
merely to enforce that distinction. Close the actual operation vocabulary and
check coverage; library methods remain open.

## 6. Where private construction helps, and where it does not

**Proposed construction contract; memory-model integration and freeze remain open.** Construction
ownership concerns compiler objects, not the native program's owners. A body may
return while its output still needs reconciliation; an inline invocation may end
while its accepted output remains in the caller's tentative construction.

| Boundary | Owner's obligation |
|---|---|
| Body returns | Receive its result/exits, current path facts and produced work; restore temporary evaluator/guard bindings on every completion route |
| Parent accepts child | Adopt the child's code, created places, bindings, requirements and call-site evidence together; branch acceptance still needs reconciliation |
| Owner discards attempt | Restore its entry facts/required surviving edits, invalidate dependent lookups, detach its indexed sites, then drop owned output; retain only named feedback and independently valid definitions |
| Body becomes publishable | Resolve construction operands and predecessor obligations; verify that every referenced identity has a surviving owner and every dependency has an admissible contract |

Accepting a child is not publication past its parent. Ordinary inline application
still operates in the caller's path state: retaining a recoverable entry does not
mean copying a universal context on each call. The implementation may use scoped
before-write records or shared immutable entries; this contract does not pick a
collection representation or promise that discarding code restores state by itself.

But the following counterexample prevents "discard the draft" from being the
whole retry design:

```text
caller binds a read of P at site A
    nested attempt writes P
        that write requires a snapshot inserted at earlier site A
    nested attempt asks to restart
```

The snapshot site belongs to surviving caller construction, not just the nested
output suffix. Borrow endings and shared escape/projection attachments present
the same ownership question. G01 is not solved by renaming snapshots to drafts.

### Revised candidate: record the need before editing the owner

Revision 2 proposed one binding per deferred tracked read plus narrow undo for
ancestor edits. Rereading the design guide's bounded edit (§2.2, §5.6) exposes a
premature commitment: **needing code at an earlier site does not necessarily mean
mutating that site now**. First ask whether the attempt can produce a requirement
that the owner resolves with the accepted construction.

Recommend keeping the binding's identity, place, version and original site as
construction data. Uses refer to the binding. A tentative write records a
snapshot requirement in its own produced work; it does not immediately replace
the ancestor's binding or allocate a temporary in the ancestor's locals list.
These are R11 construction obligations, not executable `nop`s or new source forms.

Walk the same example with descriptive names:

```text
caller: amount_read names (amount_place, original_version, before_body)
child:  writing amount_place requires capture(amount_read)
retry:  discard child's work and capture requirement; caller is unchanged
accept: pass requirement into enclosing tentative work, not around its owner
finish: resolve accepted requirement at before_body, before the write
```

The proposed ownership and completion conditions are:

1. A child sees the caller's binding identity, not permission to mutate its
   resolution. Its constructed expressions may name that binding until finishing.
2. On rejection/retry, discard its requirements with its code and tentative facts.
   No earlier snapshot was installed, so this example needs no snapshot undo.
3. On child acceptance, transfer those requirements with the child's output to
   its enclosing attempt. A later parent retry discards the accepted child too;
   requirements do not jump straight to a surviving grandparent's mutable table.
4. At the construction owner that can finish the binding, choose a captured value
   at the original site if accepted work requires one. Otherwise retain a direct
   read only where its version/lifetime rules permit it. The capture must dominate
   its uses, preserve the original path and repeat at that site on loop rounds.
5. Resolve every construction binding before publishing a body. No prepared
   expression may name discarded storage or an unresolved construction binding.

An earlier accepted sibling's requirement survives a later child's retry because
it belongs to different accepted work. If a binding was created inside discarded
work, its uses and requirements must disappear too. Requirements cannot cross a
materialized function boundary naming the caller's locals; task capture still
needs its explicit copy/rebase protocol.

**A binding's semantic lifetime is not its compiler object's lifetime.** Source
lifetime and version checks happen at the operation/use, not at final publication.
At an invocation boundary, an outgoing value must already have a valid treatment:
independent value, admitted borrowed value, or a construction binding whose
original observation and resolution obligations travel with accepted output.
If storage must be observed before it ends, capture at that original site before
cleanup. Moving the compiler record to the parent does not extend a loan or make
an unbound stale read legal. Inputs bound by the caller can remain caller-owned.

Conversely, do not resolve a surviving binding to a direct read merely because a
child returned: later accepted work can still require capture. Preserve its site
until that obligation is closed, or freeze it to an independent value at the proper
point. Current `bind`/`expire`, `return_value` and `finish_frame` have different jobs;
copying their current frame membership is not a replacement lifetime proof.

This does **not** defer borrow validation or permit stale reads during evaluation.
Binding identity denotes the value taken at its original point; its provenance
and every use still require checking. Only placement of a justified tracked-read
capture is deferred. Untracked reads and runtime effects stay at ordered sites.
The design must preserve expired-binding rules and derived expressions sharing
one bound input, not capture every read eagerly.

Narrow undo remains an alternative for a mutation that genuinely must affect
surviving construction immediately. Its contract would restore the exact prior
state, retain accepted-child undo while a parent can retry, and undo before
releasing targets. **Do not build that mechanism for snapshots without first
trying the produced-requirement protocol above.** Neither proposal has executable
validation yet; this is a refinement of the design, not a discovered compiler bug.

Apply the same ownership question, without assuming everything can be deferred:

| Data or mutation | Candidate owner and disposition |
|---|---|
| New output, locals, input/read bindings and exit sites | Creating construction owns them until adopted by its parent; no second mutable owner |
| Path contents, moved/held facts and conditional validity | Evaluation owns evolving facts; branch at control alternatives, restore the rejected owner's entry, reconcile at the actual destination |
| End a surviving borrow / detach its holder | Path-local where conditional; a required surviving attachment edit restores its exact prior state, not just "clear ended" |
| Address escape / preheader initialization | Produced demand plus path-specific stores; accepted work establishes every affected predecessor; rejected work leaves no unowned escape mark |
| Projection identity / checked-address reuse | Identity-only projections may share; computations and validity belong to their evaluation/construction and invalidate when it does |
| Call occurrence and its operands/result binding | Caller construction owns it, even when its callee definition survives; reverse indexes name live occurrences, not separate unowned expression copies |
| Function identity, unfinished body, dependency summaries | Function-build activity owns registration/completion; an incomplete dependency group cannot become an independently reusable definition |
| Allocation/arena/result/growth evidence | Revision 4 proposes planning from live allocation occurrences and transfer sites; rejected work drops its evidence. Any retained feedback still needs a dependency/correspondence proof, not a chronological ID |
| Host type identities versus decorated methods | Identity-only type data may persist; compilation-local methods/closures and caches must not retain discarded program objects |

### A retained definition does not own its callers

The [construction probe](construction-probe.lua) stages one scalar program with
two explicit calls followed by a tail edge that widens a known counter. It observes:

```text
functions=2 rollbacks=1 body_calls=2 metadata_calls=4
body_discarded_reads=0 metadata_discarded_reads=1
```

The retained callee's `call_nodes` includes an operand naming a temporary removed
from the caller's locals by rollback. This is a concrete retained-reference edge,
**not a demonstrated native miscompilation**. The probe does not run preparation.
It checks references to removed locals, not table identity: current `emit` copies
expressions, so even retained call metadata and emitted calls can be distinct tables.

`emit_call` adds both the caller's `callees` edge and the callee's `call_nodes`
entry; `rollback` truncates caller output/locals but not that reverse registry.
Later owner-result code such as `give_result_region` can consult those sites.
Consequently, scalar construction already needs call-site ownership; G01 cannot
be postponed wholesale until native owners are implemented.

**Proposed contract:** keep the execution occurrence with its caller's output;
lookup/reverse indexes either derive from live owned occurrences or remove them
when that construction is discarded. Active recursive construction may query its
own tentative sites under an explicit build owner. Publishing a callee does not
publish a tentative caller, and retaining that callee does not justify retaining
the discarded call's operands. Keep a completed definition only if its parameters,
body and dependencies remain valid without the rejected construction.

Moving validity into path facts must preserve the existing conservative joins
and callee-summary rules: a continuation cannot assume a borrow valid when one
of its reaching paths invalidates it. This representation change does not itself
authorize accepting programs forbidden by the existing lifetime contract.

If placement feedback crosses replays, it needs a valid correspondence between
allocations. A monotone fresh ID or an old chronological ordinal alone is not that
proof. Revision 4 first asks whether planning from the accepted logical allocation
description removes the need for such feedback. It does not certify the current
retained attachments or promise that every arena decision is mere renumbering.

Consequently **finishing an arm is not sealing its output**. Predecessor stores,
earlier snapshots and invocation exits may still need completion by their owner.
Function rebuilds retain their larger dependency-discard domain; frame retries
can retain independently valid materializations. Neither can retain dangling
references to discarded construction.

Before publication, check owned structure and explicit identity edges separately:
no unresolved binding, expired observation used as a fresh read, foreign-function
local, discarded operand, provisional dependency treated as complete, or abandoned
call in a live index. Check a caller's result/exit lifetime before handing it off;
compiler-object adoption cannot repair an illegal native borrow. Genuine failures
still restore compiler/loader guards; stage-safe replay is not host-effect rollback.

These checks, not a generic patch bus or transaction framework, define the first
construction milestone's obligations. Their implementation and negative tests are
still owed. Native allocations, owner release/move summaries and arena placement
constrain this construction design now; [storage derivation §7](storage-derivation.md#7-who-owns-the-description-when-evaluation-is-reconsidered)
integrates their ownership rather than deferring them outside a scalar core.

## 7. Challenge the core with the rest of the inventory

| Obligation | Does this model account for it? |
|---|---|
| W01 Branch/mutable local | Identity, path knowledge and predecessor establishment; earlier reads cannot slide past writes |
| W02 Alias loop | Accepted same-place semantics in known/residual rounds; implementation discrepancy remains. Entry/header/exit distinctions, owner-scoped reconsideration, simultaneous edges and escape before entry (§3) |
| W03 Owner result | Storage derivation works through holdings, candidate allocations, region cleanup and tentative ownership; result-to-element no-copy and Nua realization remain explicit open contracts |
| W04 Application/call | Static partial supply, saturated evaluation, distinct definition sharing; no general result memo |
| W05 Return/match | Invocation-owned landings; producer and handler joins remain distinct; no cross-invocation handler reuse |
| W06 Borrow/check/iteration | Path validity plus lending/owner lifetimes; lookup reuse needs explicit invalidation, not ordinary expression equality |
| W07 Task/capture/wait | New task owns admissible copied captures; array views rebased; blocking shares suspended frame. Not a general native closure facility |
| W08 Types/modules | Host-lifetime identities versus compilation-local bindings; loader restoration and nested-compilation rejection remain edge contracts |
| W09 Preparation/layout | Exact roots/ABI proof, task-global check before information-losing cleanup, shared C/JIT preparation; source type declarations unchanged |
| W10 Numbers/ABI | Native folding and conversion rules, not a Lua-number oracle; foreign calls have their explicit contracts |
| W11 Inspection/coverage | Checked finite semantic shapes, explicit identity edges and purpose-specific inspectors; no serialization of arbitrary host closures |
| W12 Completion/resources | Owner completes or discards its work; diagnostics retain origins, not abandoned graphs; native callable lifetime can outlive compilation |

This is a coverage argument, not proof that every mechanism already fits. In
particular, task suspension and nested-owner arena planning retain their detailed
contracts from the inventories. The three examples do not authorize reducing
those protocols to scalar joins.

## 8. What this changes, and what remains to decide

Recommend retaining the online closure evaluator, tracked places and lazy state,
ownership-aware completion and demand-driven materialization. Section 3 separates
when existing code replays from what the replacement must actually establish.
Do not mechanically preserve `Builder`'s field grouping or current tag names.

Recommend removing the general known-result cache from the initial design,
separating execution sites from reusable value recipes, and reusing reconciliation
rules instead of building separate state logic for each spelling of an exit.
Private construction should reduce undo, not pretend to abolish it.

Do **not** add a second Nua AST interpreter, global alias/heap model, generic
transaction/context/effect framework, universal outcome family for every layer,
or a promise that everything becomes immutable when a child callback returns.
Do not weaken partial specialization, lazy stores, borrowing or result placement
to make the implementation look smaller. Families follow the semantic distinctions
that survive this exercise; they do not determine those distinctions in advance.

The consequential review choices are now concrete: omit the general result
memo, enforce the ordered-site/value-recipe distinction, and let tentative work
produce snapshot requirements for its owner to finish before introducing undo.
Review withdrew the proposed private-unwind recommendation (§9): transport was
chosen before establishing which requests need it and who owns completion.
Retaining Lua closures does not settle their execution driver. None of this
certifies the existing rollback's retained attachments.

D01–D06 in [review](review.md) reference this derivation. They remain
recommendations, not an approved implementation plan. Before freeze, check these
choices against the inventory contracts and accept/amend them explicitly. The
storage obligations must be integrated before choosing a milestone. Revision 4
reopens allocation correspondence itself: do not require cross-attempt plans when
planning over accepted occurrences suffices, or hide retained feedback under
"monotonicity".

### M1 proposal: an online scalar/record compiler, not a helper migration

**Historical, withdrawn scope proposal.** The following table and exclusions
record what the user challenged, not current implementation instructions. Revision
4 integrates memory contracts before milestone selection; no exclusion here is
permission to postpone that design or introduce a new Nua refusal.

**Proposed deliverable at that time:** an explicitly selected developer entry point from Nua source,
through Mua's AST and staged Lua closures, into the new Mua-written evaluator,
checked completed residual output, shared preparation and C text. Ordinary
application and requested materialization must both work in the same program.
Production entry points stay unchanged; M1 is not a production-ready replacement.

| Included end to end | Required limits / treatment |
|---|---|
| Native numeric/Bool values, Unit results, fixed records with numeric/Bool leaves, references to that storage, function pointers with scalar signatures | Preserve native widths/folding and type identity; reuse appropriate numeric primitives, not Lua-number arithmetic as an oracle |
| Word declaration, static supply/partial application, saturation, ordinary Lua helpers and typed methods | No body before saturation; no general result memo; staged values still flow through the host, not a second source interpreter |
| Mutable locals/fields, known and dynamic branches, inline returns, ordinary references and their lifetimes | Same-place rule W02; uninitialized, stale-read and local-borrow escape refusals; field facts and lazy input snapshots remain precise |
| Known rounds/prefixes, tail loops, alias-written and nested loops, break/continue/return, address escape | Separate entry/header/exit facts; simultaneous edges; exact discard/accept rules of §6; no eager generalization of every field |
| Explicit `call`, scalar/record specialization sharing, non-tail recursion and native entry declarations | Known arguments remain specialized; same-key recursion and changed-known generalization retain their contracts; completed definitions do not retain discarded callers |
| Direct/indirect/foreign scalar calls, including unused results | One ordered execution-site contract; G02's runtime-call spelling also has a closed policy test, not a new opaque runtime algorithm |
| Completion, shared preparation and C emission for admitted constructs | Inspectable checked core; a checked lowering adapter may reuse existing backend representation, not old evaluator semantics |

M1 does **not** include resizable owners/Goose results and arenas, owner-moving or
clearing summaries, sums/immediate matches, arrays/strings/slices, tasks/channels/
slots/waits, atomics, globals or the platform/runtime libraries built on them.
Header probing and embedding through `native` are outside this text-producing
milestone; scalar foreign declarations need no header-discovery subsystem.
An admitted reference's ordinary lifetime is still checked; excluding resizable
owners does not license dangling references. Host-surface forms outside the selected source
slice need a located unsupported-feature diagnostic, not a silent route to the old
evaluator. Do not advertise arbitrary existing Nua programs as supported.

The boundary adapter must consume already completed work: it cannot settle
pending reads, reconstruct branch/loop semantics, decide whether calls execute,
or repair ownership. Reusing shared preparation requires reviewing its exact
input and correcting the G02 effect-policy discrepancy for the admitted path;
handing output to the old cleanup unchanged is not acceptance. C and gccjit keep
one prepared contract; no duplicate backend semantics or new runtime algorithms.

**No retry-transport redesign in M1.** Retain the existing targeted private control
transport provisionally where nonlocal transfer is still needed; cooperative
activity results can be checked values. This retains an implementation technique,
not a claim that Mua's guide recommends expected control as errors. It does not
reinstate the withdrawn acknowledgement/unwind framework or select coroutines.
The obligation is correct targeting, guard completion and retained-state ownership;
a concrete failure reopens the implementation choice instead of gaining a fallback.

**One integrated witness:** a statically supplied counter word, a branch that
materializes its count, an earlier scalar input preserved across nested alias
writes, a loop retaining its invariant step, and a final explicit shared call.
Run known/mixed supply variants through the whole new path. Small discriminating
cases supplement that witness: W02's required `1`, `count_down`, nested restoration,
exit-only changes, accepted-child/failed-parent capture demands, the construction
probe's discarded call metadata, and G02–G04. Do not turn current incorrect
observations or old restart counts into replacement acceptance criteria.

**Completion evidence under the current budget:** checked-family constructor and
pass coverage; inspectable entry/header/exit facts and residual sites; independent
expected known values/state transitions; negative ownership/publication cases;
source-to-C text with its shared preparation checks. No compile-heavy suite and
no automatic C/JIT execution campaign. Emitted text is not native correctness
proof; native acceptance remains unclaimed until a separately agreed small check.

The first handoff is a reviewable, end-to-end M1 result, not production cutover or
a series of completed helper migrations. Full native owner placement and remaining
language/runtime subsystems need subsequent coherent milestones and their own
acceptance. G01's scalar graph/binding obligations are in M1; allocation/arena
correspondence is not silently assumed solved by it.

## 9. Reflection after rereading the guides in full

The compiler guide (all §§0–17), general design guide (all §§0–19), Mua syntax
and `examples/lisp.mua` were reread at pinned Mua `f74545c`. The guides govern the
design method; Nua's specification still determines the language. Several details
matter more than reproducing the toy compiler's module or instruction structure.

### Decisions, results and effects before helpers

The guide's pure-core principle suggests a small separation inside reconciliation,
not a new whole-program planning layer. For **already captured ordinary scalar
contents**, agreement can answer `agreed(contents)`, `uninitialized`, or
`requires_storage` for a nonempty set of live predecessors. It does not emit
stores, take addresses, query mutable views or end borrows. Equality must use the
appropriate native value/version identity, not arbitrary table equality.

The enclosing reconciliation activity establishes the chosen result on each
predecessor and completes ownership obligations. Reference reification can expose
further storage, so that activity must revisit affected places. A pure agreement
function alone cannot claim that the whole join is pure or complete. This keeps
one evaluator with testable decisions, not separate pure/effectful evaluators.

### Review finding: completion ownership was assumed, not derived

**The earlier D03 recommendation for private unwind is withdrawn.** The user
asked for review, not approval or rejection of that mechanism. The recommendation
favored preserving the existing execution stack before testing a different
ownership arrangement. The guide's instruction is stronger: the activity owns
completion (§5.5–§5.6); decide that responsibility before choosing transport.

The [earlier probes](retry-probes.lua) and their raw observations remain valid:
Lua discards an assignment hook's return, abandoning a coroutine does not run its
remaining code, and protected scopes can rethrow a private error. But the design
conclusions were too broad:

1. **The coroutine comparison put completion in the wrong participant.** Its
   `scoped` helper runs inside the abandoned body. That rejects stack-dependent
   completion, not a driver that completes its owned work after receiving a
   yielded request. Such a driver need not resume the rejected body's suffix.
2. **Public hook contracts were conflated with current bookkeeping placement.**
   Syntax §16 permits Lua hooks returning values/places/words. It does not require
   `run_hook`'s global `in_hook` table or the map library's shared iteration stack.
   Hook suppression, loan validity and iteration restrictions must survive the
   rewrite; where their compiler-owned state lives is precisely a design choice.
3. **"Narrow" was not demonstrated.** The proposed unwind bridge needed carrier
   branding, pending acknowledgements, checks on subsequent staging, exceptions
   for cleanup, exact rethrows and error-decorator cooperation. The model only
   refused publication *after* an intercepted carrier's host suffix ran. It did
   not establish that those obligations are smaller than an owned driver protocol.
4. **Retry causes were grouped before being examined.** Some are explicit control
   decisions or construction-completion feedback; others genuinely arise deep
   inside an expression. A transport for the hardest case should not dictate
   every activity's result protocol.

This is not permission to discard arbitrary host resources. Syntax §4.5 requires
stage-safe typed computation and rules out arbitrary Lua I/O/opaque FFI effects
there; it does not prove every Lua hook has no completion obligations. Conversely,
those restrictions must not be strengthened into a blanket ban on ordinary host
functions. Compiler-owned bookkeeping, residual native cleanup and host-owned
resources are separate obligations. No proposal may silently conflate them.

### Separate the reasons before choosing their transport

The source gives the following distinctions, not mandatory replacement variants:

| Current discovery site | Problem | Replacement question |
|---|---|---|
| `S.tail`, `S.loop_next`, `S.loop_exit`, `jump_next` | Finish a known round, generalize an edge, or emit residual control | The explicit control decision can produce an outcome through generated bodies; operand evaluation may still discover a deeper invalidation. An emitted native jump is not itself a compiler retry |
| `ex` handling `round_of`, and `S.loop` round-local copies | Reference identity conflicts with the round-copy representation | Preserving original place identity (§3) may remove this repair-specific retry; it does not remove address-escape obligations |
| `Builder:loop_write`, `loop_escape` | A write reveals participating state; address exposure also changes storage/tracking requirements | Do not equate discovery with failed header agreement. Check continuing edges; preserve pre-loop initialization and escape rules (§3) |
| `Builder:apply` on changed known arguments under dynamic control | Continuing to unfold does not establish a finite residual computation | Generalize the owning invocation; do not assume every request can wait until the body returns |
| `h.finish_ref_moves`, `build_function`'s `pending_arena` completion | A completed construction discovers summary/placement feedback | Local completion can return feedback directly; an invalidated outer construction still needs routing and its larger discard domain |
| `h.place_result` during a return | Selected owner needs a different native result placement | Review with the owner-placement protocol; neither a scalar transport trick nor "defer everything to preparation" solves allocation correspondence |

This narrows what needs nonlocal handling without claiming that replay disappears.
A pending-invalidity flag plus fabricated values is not an alternative: subsequent
Lua control flow can diverge or produce false diagnostics before reaching a check.

### Countermodel: the driver completes outside the suspendable body

[The review probes](retry-owner-probes.lua) test a different ownership arrangement:

```text
activity driver owns draft and completion
    run the body -> ordinary result, targeted request, or genuine error
    restore the driver's active binding and complete its own draft
    accept output, keep an accepted known round, or discard rejected work
    forward an outward request only after the inner activity completes
```

In this bounded model, an assignment hook yields through `pcall`; the inner and
outer drivers complete once each, in order, without executing either rejected
suffix or throwing the request as an error. Normal completion and known-tail
transfer keep work; retry and genuine failure discard it. The body still uses
ordinary Lua assignment and successful value returns. This is enough to refute
our earlier inference that preserving that hook shape forces exception transport.

It is **not a proposed production coroutine implementation**. Its completion is
only toy draft/binding management, not Nua's loans, earlier read bindings, shared
attachments or function graphs. In a real design, compiler-owned hook/iteration
context would have to be owned or inherited explicitly; abandoning a stack with
the *current* shared marks would still be wrong. Suspension is an explicit driver
protocol, not the guide's simple body-return example transplanted unchanged.

The same probes expose a serious remaining edge: a **host-owned coroutine** can
intercept `coroutine.yield(request)` and deliver the request as ordinary iterator
data. The outer driver then sees successful completion. Thus a bare `yield` is
not a complete transport either. Generator routing, host-call yieldability,
thread-sensitive host behavior, scoped-context inheritance, diagnostics and cost
all need concrete treatment before choosing this substrate. No silent restriction
of the existing Lua host contract is authorized.

### D03 disposition after review

**Proposed provisionally for M1; freeze reopened, no coroutine choice made.** The withdrawn new unwind protocol
stays withdrawn. Section 8 now proposes preserving the existing targeted transport
for M1 rather than making its redesign a prerequisite; this is explicitly not a
claim that the guide prescribes error transport. Retain checked results between
cooperating activities. Whatever carries a remaining nonlocal transfer must obey:

- A target names a live attempt/continuation owner, not just a word/source line.
- The owner of tentative work also owns its acceptance/discard and guard state.
  Accepted child work remains tentative relative to its parent; cleanup is once
  per owner, not a side effect of a particular exception path.
- Known-tail transfer retains accepted work; retry discards unfinished work;
  function rebuilds have their own dependency domain. A native return is separate.
- Hook suppression and lending/iteration rules hold on normal completion, retry,
  outward transfer and failure. Genuine errors remain errors, with provenance.
- No request becomes a native operand or host iterator datum; no stale output is
  published. Transport integrity must be tested across actual supported host
  boundaries, not only cooperating synthetic closures.

The scalar-loop traces (§3) separate state discovery, structural completion and
failed header assumptions, including an earlier bound read. Sections 6/8 now state
the construction handoffs and scoped milestone to review. Their completion checks
must exercise the admitted host boundaries; full lending/owner placement still
requires its later milestone. If state discovery no longer aborts an ordinary
write, that path no longer needs nonlocal transport. Neither private unwind's
necessity nor a complete retry-free replacement has been established.

### Show the work before testing the final answer

The first operation over each new family should inspect/print it (§6.3), with
closed pass coverage, meaningful full names and source origins. For the initial
end-to-end milestone, make these observations independently inspectable:

- supplied requirements and whether a body ran;
- predecessor contents and stores established at their continuation;
- distinct entry/header/continuing/exit facts, place targets and loop-input bindings;
- deferred read bindings, owned requirements and their completed resolution;
- specialized function identity/body, separate from ordinary inline output;
- rejection and retry results, including unchanged surviving construction.

These are phase observations, not promises to serialize arbitrary Lua closures.
Explicit expected transitions are needed: agreement between two backends consuming
the same incorrect IR is not an independent oracle. A bounded reference model
can help where its semantics are independently defined; no second production AST
interpreter or Lua-number stand-in for native arithmetic is justified by §8.

The guide also says to build an end-to-end skeleton once its contracts are ready,
not perfect every diagram first. After the remaining material choices and scoped
freeze are approved, the next evidence should be executable Mua with contracts,
inspection and cheap completion/refusal checks—not another inventory expansion.
The existing no-implementation-before-freeze and no-heavy-tests constraints stand.

### Evidence and checks

The Nua evidence remains source reading of syntax §§3–7 and §9, the cited
examples/rejections, and `stage`'s joins, read binding/snapshots, retries, loops,
application and owner results. Revision 3 adds the full guide reread, the read
binding/construction investigation and the hook/retry/completion traces above.
The earlier `retry-probes.lua` run passed 15 Lua-mechanism assertions; its source
and raw evidence are retained. The review's `retry-owner-probes.lua` passed
9 model assertions, including the unresolved host-coroutine routing counterexample.
Neither is Nua acceptance evidence. Separately, `evaluation-trace.lua` completed
ten real staging-only cases and recorded the observations in §3; its raw runs
are kept under `build/logs/compiler-evaluation-trace-v*.txt`. It does not run
preparation or native acceptance. `loop-boundary-probes.lua` additionally completed
four staging-only cases: nested header restoration and known/dynamic read-only
aliases. Its first run stopped on a probe-instrumentation error (optional place
metadata was accessed through Nua's member hook); after using `rawget`, all four
completed. Both raw runs are retained under `build/logs/compiler-loop-boundary-probes-v*.txt`.
`construction-probe.lua` then completed one additional staging-only program,
observing four call-metadata entries versus two residual calls, with one metadata
read of a removed temporary (§6); raw output is in
`build/logs/compiler-construction-probe-v1.txt`. No native compilation or compile-heavy
suite was run. Documentation checks and revision 1's [baseline discrepancy probes](review.md)
remain separate.
