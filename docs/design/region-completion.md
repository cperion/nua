# Affine regions, completion and native task execution

**Approved architecture.** The user approved this combined contract with “yes i
approve” after the coordinator's review of independently reclaimable regions and
the correcting native-scheduling design. This is the architecture for the
replacement compiler, not a claim that the current compiler/runtime implements it.
[Syntax](../syntax.md) owns the language/ABI contracts;
[architecture](../architecture.md) distinguishes the target from current code.

This completes the architectural prerequisite to beginning the replacement,
including its IR/activity infrastructure. Implementation must proceed in coherent
end-to-end milestones, not a scalar-only core with ownership deferred. The earlier
[completion proposal](compiler-completion.md) and [regional
experiment](compiler-region-experiment.md) remain historical evidence; their fixed
roles, marks and bounded analyses are not the adopted allocator or boundary ABI.

## 1. Decisions and compatibility

1. **Replace fixed physical indices and packed position stacks with affine runtime
   regions and independently reclaimable blocks.** Positions remain finite logical
   layout/invalidation classes. Actual live reservations and metadata can grow with
   runtime ownership and recursion; native signatures and type topology do not.
   This is heap-like reservation/free machinery, not a pure stack allocator. It
   introduces neither tracing GC, reference-counted language ownership, implicit
   borrow promotion nor a source-level pointer-owned object graph.
2. **Actual owning transfers permit relocation and end old contents loans.** A
   standalone handoff normally transfers its region without copying payload. A
   shared fragment or destination normalization can require copying. Copy elision
   does not preserve a pre-transfer contents loan. Reacquire from the destination.
   A reference to the source header does not retarget to that destination.
3. **Retain the existing logical compaction/invalidation boundaries.** Immediate
   independent block retirement replaces physical packing, not the timing of
   caller-side native completion or other prescribed cuts. The earlier proposal
   for eager logical compaction is not adopted.
4. **Use nonmoving task-owned native stacks and explicit budget safe points.**
   Same-thread context switching preserves native frames while returning to the
   scheduler. Seeded mode retains one plain-thread executor and starts no workers.
   The reference ordinary scheduler uses lifetime worker affinity, not migration.
   A platform context facility replaces the C99-only/no-stack-switch description.

A join or backedge transporting the same installed holding is not a new source
move. Neither are compiler-only capture/result transport or private preparation
copies. Stable growth retains its guarantee. Conditional/last-use moves, the
prohibition on moving out through unknown Ref targets, ordinary conservative
borrow rules, Store identity, task sendability, source-wait restrictions and
foreign ownership restrictions remain.

Preserve Mua AST hosting and staged closures, integrated evaluation/residualization,
source-effect order and [one program IR](compiler-activities.md). There is no old
evaluator fallback, second source interpreter or backend ownership semantics.
Allocation policy, typed relocation, reclamation, recovery and scheduler policy
are ordinary Nua words. Lua supplies hosting, types and compiler facts; C/assembly
supplies only necessary platform/ABI mechanisms.

## 2. Actual resources and exclusive custody

| Record | Contents and responsibility |
|---|---|
| Storage context | Plain-thread/task allocator state, metadata pages and active recovery-domain chain |
| Recovery domain | Stable entry-boundary record listing its current regions and active storage operations; not a source exception scope |
| Place Home | Persistent header-place identity and receiving lifetime/domain; static for a global, nonmoving frame storage for a task local |
| Region | One current custodian/domain/Home, allocated-block list and root layout information |
| Block | Actual allocation base/reserved size, used extent/capacity, logical position, region and allocator links |
| Owner header | Current logical fields, region/block references, storage guarantee and custody kind |
| Operation | Stable preparation/publication/retirement state, provisional resources, prepared header images and retirement plan |

A region has one custodian: a source holding, complete temporary/exit holding, or
an operation before publication. Domain registration is nonowning bookkeeping,
not another source owner. Independently movable standalone owning fields normally
have separate regions; a sum visits only its active owning fields. Nested owners
are fragments in their enclosing region and cannot release that entire region.

Stable/shared storage guarantee and whole-region/fragment custody are distinct.
A stable fragment needs a nonoverlapping growable reserved subrange or fixed-size
storage; sharing custody alone cannot justify relocating it. A nested header
names its stable region, not a cached parent-header address that would need repair
when a parent array moves. A region's root locator changes on standalone handoff.

Empty live ownership is distinct from moved state. Release uses the recorded full
allocation base and size, never a current payload base or reconstructed suffix
mark. Reusing an address or allocation site revives neither a loan nor an ID.

### Allocator bootstrap and reuse

A standalone growable position uses a private nonmoving window under the configured
thread/task capacity policy. Check arithmetic and reservation bounds before
publishing growth. No unrelated root allocates above it. Nested storage uses
individual capacity-sized blocks; empty data need not acquire a payload mapping.

The platform reserve mechanism returns success/failure plus the actual provenance
needed for release. Register each successful acquisition before another fallible
call; convert failure to a trap only from a consistent state. Policy and checked
size/alignment calculations remain Nua, not a C region allocator.

Metadata uses raw pages, not ordinary owning values whose transfers would recurse
into their own implementation. The context has bootstrap storage. Initialize a
new page's header inside that page and link it before further allocation. Fixed
records use page slots/free bitmaps; variable plans and header images use raw runs
owned by the operation. Pages belong to the durable context, not the domain that
first used a slot. A promoted global/outer region cannot lose its descriptors when
an inner entry ends. Its context survives for its required lifetime.

Return record slots and release empty pages and unused payload reservations. No
unbounded cache/history is required. Freeing and recovery allocate nothing. Pure
region end moves the record to a retiring list and uses the record itself as a
cursor until its blocks are released. An allocating mutation obtains its operation
record before changing the target.

### Genuinely shared extents

An indivisible allocation containing a prefix and several fragments has one
explicit enclosing custodian. Moving/ending a fragment cannot free that allocation.
Detach an escaping fragment into independent storage before its custodian ends;
then the custodian releases the old allocation once. No returned native frame
remains a hidden custodian, and no reference count is introduced.

Replacement blocks are independently reclaimable; repeated replacement does not
append unreclaimable history to the shared extent. A genuinely pinned backing
extent can remain while its real custodian/protectors require it. Manufacturing
shared standalone storage must not silently weaken stable-storage guarantees.

## 3. One storage-operation protocol

```text
PREPARE → READY → COMMIT → RETIRE → DONE
```

1. **Evaluate/capture in source order.** RHS words, selectors, arguments, callbacks
   and source waits occur at their prescribed points. Capture each value before a
   later effect could change it. An owned capture is a complete holding, not a
   postponed reread. Resolve/check the actual target once at its source access;
   do not repair a Ref that intervening effects invalidated.
2. **PREPARE.** Register the operation, measure the typed value and affected old
   subtree, validate lengths/tags/occupancy/arithmetic/capacity, and record exactly
   which old exclusive allocations will retire. Acquire/build unreachable new
   contents and final header images. Old holdings remain authoritative. Hashes,
   token acquisition and all fallible decisions happen here or earlier.
3. **READY.** All resources and checked addresses/sizes exist; the prepared images
   describe complete values. Static lifetime checks establish that external
   borrowed fields survive the operation's cuts. No user code runs inside the
   structural preparation walk to mutate the selected target unexpectedly.
4. **COMMIT.** Splice prepared chains, install fixed-layout images, update current
   custody/Home/domain and clear consumed source custody. Publish the specified
   logical transition. This is bounded by native type layout, not runtime element
   count. Same-place self-assignment is identity, not destroy-and-copy-to-self.
5. **RETIRE.** Free the recorded obsolete exclusive resources and then the operation.
   Bounded steps may yield; no next source operation begins with this operation's
   retirement debt still outstanding.

COMMIT contains no allocation, token generation, hashing, checked indexing,
trapping arithmetic, new selector lookup, user callback, fallible/reentrant foreign
call, pool give/adopt/release, scheduler poll or suspension. Runtime-length payload
copies happen in PREPARE; runtime-length frees happen in RETIRE. Fixed-layout byte
moves use already checked addresses and sizes. The trusted Nua kernel enforces
this instruction/effect contract; “the next check probably succeeds” is not enough.

Prepared nested headers name the final region, but their provisional block chain
belongs to the operation until its constant-size splice. Abort frees that chain
without unlinking it from a live region it never joined. Live allocation links and
retirement-plan links are separate. Whole-region and subtree retirement entries
cannot independently cover the same resource. Recovery settles operations before
domain sweeps, preventing double frees or leaked obsolete global blocks.

PREPARE/READY failure discards raw provisional resources without interpreting
incomplete source values. RETIRE failure handling completes recorded retirement;
new holdings are already authoritative. Cursors advance only at completed,
nontrapping microsteps. Necessary raw reserve/release/byte primitives have explicit
non-reentrant/status contracts. Hardware faults and illicit foreign longjmp are
not recoverable Nua capacity failures.

## 4. Typed traversal, growth and logical cuts

The finite type schema distinguishes ordinary values, external borrowed/raw
fields, owning child headers, active alternatives, initialized ranges, sparse
occupancy/generations and declared internal representation links. Owning type
depth is finite; runtime element counts become ordinary Nua loops. References and
IDs are not traversed as owning edges. A user pointer is not an internal link
merely because its numerical address falls inside copied storage.

Prepare allocates parent/header destinations before children and completes child
headers before publishing their parent:

- Records process independently owning fields; sums visit only the captured active
  tag. Never read an inactive alternative as initialized owning data.
- Grow/Array/Text preserve promised capacity and copy initialized contents only.
  Spare capacity is not read or dropped as live values.
- Store preserves token, slot numbers, generations, occupancy, free/retired state;
  visit payload only in occupied slots. Relocation and `copy Store` preserve its
  token as specified; fresh creation obtains a new token before READY. Address
  reuse never reverses generation retirement.
- Map prepares its slots, index and owned key storage. Rebuild declared index/key
  links from prepared slot/hash information; arbitrary user Str fields remain
  external borrows. Hash/index computation is not publication work.
- External borrow bits retain their lifetime relation. If the source operation
  ends that relation, reject the containing transfer; do not invent self-pointer
  repair. Raw pointers retain their unsafe contract. Atomic/foreign noncopyable
  representations retain their existing restrictions.
- Slot handle transport within a task is not pool give/adopt/release. Discarding a
  handle is not an implicit destructor; unreleased slots remain out until scope
  retirement under the existing contract.

**Growth is not indiscriminate deep transfer.** Stable growth retains its private
window and prefix, building/checking the tail before publishing length. Shared
parent-array growth transports initialized header representations to a new parent
block but retains already-owned child blocks in the same region. Retire the old
parent block only. A moved parent-header address ends its dependency; a separately
valid child-payload view is not gratuitously killed by deep-copying the child.
Map index rebuilding similarly does not move stable entry slots unnecessarily.

A private standalone handoff adopts its region and updates the receiver's Home;
fragment detachment/full relocation uses the typed traversal. Overlap is handled
by private preparation before destructive retirement. Direct construction and
adoption can avoid copies but are not correctness premises. A swap captures the
actual incoming holdings before overwriting either place; payload-address equality
is not proof of source-place identity. Consuming one holding twice remains invalid.

### Compaction and bounded storage

Independent retirement frees obsolete blocks without moving siblings. Preserve
root-position cuts at rooted operation completion, deferred native abandonment
cuts at caller completion, and explicit compact's prescribed cuts. Ordinary
shared growth has its own footprint, not an added whole-root cut. These are
semantic IR events; physical compaction may move no live bytes. The old packed
arena/dead-byte/4096 heuristic is not the new physical allocator. The old checker
already ended loans before that runtime threshold test.

A returned view acquired before a pending caller-side cut cannot be relabeled a
post-cut view. Reacquire through a surviving header or genuine checked root/index/ID
lookup after the call. A readonly accessor, or a standalone-target mutator with no
such pending cut, can still return its valid borrow. A Home grants authority, not
pointer repair.

Repeated replacement retains current/promised reservations, the current operation's
prepared and retiring resources, its temporary plan, allocation/page overhead, and
any genuinely pinned shared extent. It does not retain a term proportional to
completed iterations. At operation completion the provisional/retirement/plan
terms disappear. Actual live recursive roots still consume actual resources.

## 5. Native boundaries, loops and compiler agreement

Native owner/result representations are finite typed headers/region handles, not
variable cleanup-history vectors. Caller-supplied result holdings have fixed
layout. A Ref remains one pointer; its owner pointee has the new header ABI,
including distinct storage guarantee and custody kind. Nested headers refer to
stable regions, not an enclosing element's cached address.

The boundary protocol is:

1. Evaluate/capture arguments in source order into complete holdings before user
   callee execution, including completing a required fragment transfer.
2. Execute with independent local regions. A Ref mutation uses its actual current
   header, regardless of the ancestor/site that created it.
3. Capture a return into a complete owned exit holding. Perform required source
   activity completion in order, retaining that holding across legal waits.
4. Hand the result to the receiver, update surviving custody, and close remaining
   callee holdings before their frame disappears.
5. Apply native logical completion effects, including pending shared-position cuts,
   before caller continuation and returned-borrow validation.

Source capture, activity completion and destructive transfer remain distinct. A
frozen owner cannot move before its legal join point; an already legal capture
cannot be delayed past completion that would change its observed value.

Hidden argument-or-fresh choices transfer the actual selected holding; other
resources end on their actual edges. Two results have independent authorities,
with detachment where needed. Recursive forwarding does not change interface
width. Larger cohorts and late-selected reference targets use this same protocol,
not early scans, a root bank, SCC placement coloring or source replay. The old
physical obstruction to growing an older independent result no longer exists.

Lifetime/alias/effect agreement still matters. Preserve ordered use/kill constraints,
including nonreturning prefixes: killing argument A and then reading view B is not
safe merely because an unordered final summary omitted the read's timing. Apply
call-site alias substitution and distinguish loans acquired before/after cuts.
Preserve reference origins and storage guarantees through fields, joins and
materialization. Unknown indices retain the ordinary conservative rules, not an
additional placement bound.

A loop carries persistent source places and relations such as `view borrows
H.current_contents`, not an infinite set of concrete epoch numbers. Replacement
ends the old contents; a refreshed view relates to the new contents. The backedge
itself neither moves that installed holding nor ends the refreshed loan. Missing
refresh remains invalid even if a descriptor/address is reused.

Storage realization needs no whole-program placement fixed point: finite type
schema supplies finite visitor code, runtime lengths/tags supply traversal bounds,
and raw allocation supplies actual independent resources. Knownness still controls
binding time. Arbitrary host computation/specialization need not terminate, and
ordinary conservative lifetime analysis is not a decision procedure for arbitrary
mathematical facts. Neither limitation is used to refuse a required placement.

Activities own their facts, generated definitions and output in the same IR.
Rejected construction discards them; it does not execute runtime releases. Physical
resource binding does not replay source. Follow the current Mua stateful-vocabulary
factory discipline and family handlers `(node, recurse, ...)`. Both backends consume
common realized storage and budget effects; backend inlining is not a substitute
for ordinary Nua specialization.

## 6. Recovery, globals and foreign access

Recovery domains track current custody, not allocation age. Replacing an outer
owner/global assigns new resources to the destination Home's domain at COMMIT,
even if allocated in a nested entry. A plain recoverable trap first aborts or
finishes registered operations according to phase, then releases regions still
owned by abandoned domains, then restores the enclosing entry context. Never read
abandoned C-stack headers or invoke arbitrary source destructors during recovery.
Nested catches preserve still-live outer domains. Globals survive ordinary recovery.

For deep replacement of a global G, PREPARE keeps G's old complete representation
while all new resources are provisional. Capacity failure frees the provisional
resources and leaves G as it stood after preceding source effects. COMMIT publishes
a complete new G; subsequent recovery finishes old-resource retirement and keeps
that new G. This is storage consistency, **not rollback of earlier source effects**.
Token counters can advance without a published Store; uniqueness is not consecutiveness.

First-use global initialization has a static Home and an uncommitted thread/context
claim. Prepare descriptors/tokens before publishing a complete empty owner. Failure
clears the uncommitted claim; another thread never sees partial initialization.
After publication retain first-use thread affinity and the prohibition on task use.
The global's context and metadata survive for its lifetime.

A fixed C `Fn` keeps its declared signature and cannot transfer owners by value.
Foreign Ref/slice access requires a correctly initialized Nua-managed header,
valid borrowed lifetime/context access and the mutation/retention/live-loan contract.
Host-supplied header memory needs an explicit Nua-managed initialization/lifetime
wrapper whose outer domain owns the cell until end. This is not an old-layout or
forged header, nor implicit promotion of a source borrow.

Foreign callbacks occur only with complete source holdings, never during COMMIT.
Reentry creates its own domain, but permitted outer-target mutation adopts into
the outer Home's domain. A nested trap does not sweep that committed value merely
because its allocation was young. Surviving ownership does not revive expired
borrow fields. Raw foreign longjmp, unsynchronized mutation or retention beyond
contract remains unsafe. Closing files or other foreign activities is ordered
source completion, not a hidden region destructor.

The actual trap policy remains: task execution, selected task storage (including
blocking jobs), and open task scopes cannot recover through `nua_try`; they abort.
Plain entry recovery remains the minimal setjmp/longjmp mechanism calling Nua
cleanup policy. No new source exception or cancellation facility is introduced.

## 7. Native tasks without a second evaluator

A task owns a nonmoving typed frame, region context, native execution-stack
reservation and fixed saved-context/run-state record. Its source-wait continuation
is the existing step-function state. Its budget continuation is the actual saved
native PC/register state and stack. A trampoline calls the generated step; native
words use their ordinary call/return ABI on that stack. A budget park returns to
its call site without serializing arguments, replaying evaluation or moving owners.

Every residual Nua loop has a budget operation in common prepared IR. Known
recursive native-call cycles also charge intra-cycle edges after complete argument
capture and before callee entry. Plain non-task execution does not schedule at
these points. PREPARE/RETIRE service budgets between bounded completed steps with
stable cursors. Automatic service is deferred only through bounded critical
microsteps, not runtime-length walks or callbacks. COMMIT has no safe point.

### Dispatch and continuation lifetime

With workers enabled, assign each task to an existing worker at publication using
a scheduler-owned distribution counter. Only that executor runs it for its lifetime;
blocked plain parties wait rather than taking worker-affine activations. With no
workers, tasks run on the blocked plain executor; nested task scopes retain that
executor. Mandatory joins and worker shutdown keep executors alive until their
assigned tasks end. There are no pinned OS activations, replacement workers or
native-resume tickets.

Under the scheduler claim/lock discipline:

1. On the scheduler stack, select/unlink READY, claim RUNNING, save the executor's
   current Nua context, install the task's context and switch to its saved context.
2. A budget park records BUDGET and switches back. Keep the task claimed until
   control is on the scheduler stack; only then publish READY and enqueue once.
3. A source wait records its typed frame continuation and returns WAIT to the
   trampoline, which switches back. Reconcile early wakes/notified state before
   deciding READY versus WAITING.
4. SOURCE_WAIT resumption performs completion/withdrawal/Slot adoption once before
   reentering the step. BUDGET resumption returns to the native PC and must not
   replay that work. START is distinct from both.
5. DONE is published only after source completion and all variable-size domain/
   operation retirement finish on the task stack with budget service. Switch away
   permanently; fixed bootstrap/control/frame/stack release happens on the scheduler
   stack. Remove registry/queue links before detaching and waking the scope waiter.

A wake from another worker only enqueues on the assigned executor; it never resumes
the context there. No pending I/O/blocking job can own a DONE frame. A task records
a stable executor control record, not a pointer to an earlier `nua_block` activation.
Every dispatch freshly saves its scheduler continuation; a plain executor may
return to source and block again without leaving a task aimed at an expired frame.

The scheduler/context primitive cannot recursively budget-poll under its own locks.
Long scheduler work uses bounded lock transactions. Saving/restoring Nua-selected
TLS is explicit; the entire C TLS image is not virtualized. Budget effects invalidate
relevant shared/TLS/extern observations, not the ownership/place/contents epoch of
private task data merely because another task ran.

### Seeded service and foreign extents

Seeded mode executes task quanta on one plain OS thread. Context switches consume
no PRNG draws. At a service round's start the ready queue becomes its finite
eligible cohort. Seeded selection removes one eligible member; yielded, newly
spawned and awakened tasks join the next round. An unserved member cannot be
indefinitely displaced. Ordinary mode uses FIFO choices in the same per-executor
round protocol. Intrusive task links avoid yield/round allocation.

Seeded `first_of` retains its ticket-selected cyclic starting case and source-order
scan. Scheduling and ready-case draws follow their execution order, not allocation
addresses, copy duration or OS thread IDs. Replay is for the same program/runtime,
seed, initial state and supplied external-event trace; it does not promise unchanged
schedules across runtime versions or determinize real I/O/timers/foreign host state.
Two infinite known native loops can alternate quanta without either returning and
without recursively dispatching one beneath the other's native stack.

Known Nua calls keep their ABI and budget capability. The private `task.step` field
and runtime/storage bindings carry trusted Nua-entry provenance in construction/IR;
a matching C signature alone does not confer it. Otherwise fencing the step's
indirect call would disable every task budget. The context switch is a described
control effect, not an opaque call fenced against its own switching.

Opaque C `Fn`/foreign invocations enter a foreign extent after argument capture.
Do not switch while it is active, including during synchronous Nua callbacks
beneath the foreign caller. Accumulate budget debt and service it at the next
permitted Nua point after the outer call returns. This retains the unchecked-long-C
exception and avoids reentering a foreign library or its held locks on the same
thread. Direct known Nua execution is never fenced merely because it emits C.
An unknown pointer that happens to name Nua code remains opaque unless proven.

Lifetime affinity preserves thread identity, not task-private C TLS/errno/hidden
state. External entry does not acquire an unrelated suspended task; synchronous
reentry inherits the active foreign extent. An inner catch cannot unwind and later
resume a task activation. Explicit `blocking` jobs use outside-scheduler mode and
exclusive waiting-task context/frame access, not that task's saved budget context.
They cannot run a second copy of its step. No ordinary native/storage loop is
implicitly converted to a blocking job.

### Platform mechanism and resource lifecycle

The platform facility initializes a C-ABI trampoline on supplied aligned stack
storage, switches ABI-required registers/stack/continuation/control state on the
same thread, and supplies raw reservation/guard/release mechanisms. It must respect
alignment, red zones, floating-point control and shadow-stack/control-flow
protections. C and JIT compilation require the same frame/page-probing discipline:
a large frame must not jump over a guard. Foreign code retains its stack-safety
obligations. Fabricating a stack pointer with ordinary setjmp is not sufficient.

No allocator policy, scheduler selection, source interpreter or ownership walker
belongs in this platform facility. Both backends call the same runtime policy and
mechanism. Switch calls are visible control/memory effects, not eliminable pure
copies. Unsupported target mechanisms require a real port, not a hidden thread
fallback claiming seeded conformance.

Before publishing a spawn, acquire/initialize frame, control record, context
bootstrap, native stack and initial saved context; register each acquisition before
the next can fail. Preserve capture/Slot/scope ordering. Failure releases the raw
construction list without interpreting uninitialized frame fields. A budget save
then allocates nothing. Source waits use their existing operation records.

Each live task retains its stack reservation until DONE. It has a finite configured
native-stack resource limit; never relocate live frames to grow it. Exhaustion is
fatal in a task, not recoverable rollback across contexts. Completed stacks are
released; an unbounded free-list history is not required. Scope join does not cancel
an infinite task, but its permitted budget points cannot starve the finite ready
cohort. A budget-parked task is READY, not a false deadlock's WAITING party.

## 8. Scope, channel and pool completion

Scopes join children before retiring channels/pools. Sendability and source waits
inside materialized native words retain their existing restrictions; this design
does not silently add frozen-parent borrowing or permit new source waits. When a
separately legal holding must survive a join, keep it complete at its valid place.

Pools own stable slot storage with scope/generation/task-owner checks. Ordinary
storage relocation within a task transports handle bits without changing the
recorded task owner. Successful send/give transfers to the operation/channel;
receive adopts before access. Withdrawing a losing send restores its slots once.
Explicit release returns a slot or hands it to a waiter. Scope retirement makes
stale handles fail without reaching freed records. Ending a value is not a hidden
Slot destructor. Existing unsupported Slot-in-sum message shapes remain unsupported.

I/O retains checked buffer access while its task waits; no simultaneous task copy
mutates that storage. Pool buffers remain out until operation completion and the
source's explicit release/send. Context switching or a blocking thread does not
change recorded Slot ownership.

## 9. Required cases, costs and implementation evidence

| Required case | Operational answer |
|---|---|
| Independent choice/swap and empty reservations | Actual correlated holdings carry region authority; empty live state differs from moved; allocation records account for full resources |
| Hidden argument/fresh result and forwarding | Transfer selected complete holding; finite result ABI, no reconstructed branch history |
| Shared extent and partial escape | One real custodian; detach escaping fragments before it ends; release shared backing once |
| Recursive combination, ancestor mutation and intervening scratch | Independent reservations remove growth/release interference; no root-bank or depth-specific ports |
| Late target from a variable-length reference collection | Select/read current target at its source point; no early scan or placement refusal |
| Loop replacement/current-header aliases | Persistent place, current-contents relation, retirement per operation, real checked reacquisition after cuts |
| Sparse/container relocation | Typed active/initialized traversal, capacity and ID preservation, declared internal links only |
| Global deep replacement and failure | Private preparation, nontrapping publication, durable phase-aware recovery |
| Early exit/returned borrow/task join | Complete capture, ordered completion/transfer, boundary cuts before borrow validation |
| Native loops and long storage walks in seeded mode | Nonmoving native contexts on the sole executor; bounded-step budgets; no switch in COMMIT |
| Foreign reentry/pools/I/O | Explicit context/domain/foreign modes and existing scope/generation/custody contracts |

The costs are real: per-region/block metadata and mapping overhead, private stable
reservations, possible deep copies, transient old-plus-prepared storage, per-task
native stacks, platform ports and worker-affinity imbalance. Resource exhaustion
can happen where the old allocator succeeded. These are runtime resource costs,
not static cohort bounds or new placement-based source exclusions.

The preservation argument rests on unique custody, disjoint stable growth ranges,
complete published values, surviving Home/domain endpoints, non-revivable loans,
phase-correct recovery and one executing continuation per task. Creation establishes
these invariants; preparation preserves old authority; bounded publication transfers
it; retirement acts only on recorded obsolete resources. A context save preserves
addresses/lifetimes until normal return and relinquishes execution before queueing.

This approval resolves the mechanisms, not their implementation correctness.
Required work includes ordinary Nua allocator/storage/scheduler code, common-IR
ownership/effect/budget realization, platform ports and independent tests of
lifetimes, resource ledgers, failures and replay. Earlier probes retain exactly
their bounded historical results; none validates this new allocator/context runtime.
No executable validation or replacement code accompanies this adoption document.

### Provenance

The approved package reconciles solver reports `NUA-COHERENT-MODEL-20261107-D`
(independent regions) and `NUA-COHERENT-MODEL-20261107-E` (correcting native budget
suspension). E replaces D's pinned/replacement-thread and unconditional-FIFO
mechanism, not the seeded no-worker contract. Private originals and the coordinator
review remain under ignored `build/reflection/`; this tracked document records the
integrated contract without depending on those local paths. Earlier fixed-pool
reports and experimental failures remain evidence, not alternative compiler modes.
