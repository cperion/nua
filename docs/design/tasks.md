# Tasks: native stacks and context switches

**Approved design.** The native task runtime was approved with the earlier region
architecture (2026-11-07); the [buffer model](buffers.md) (2026-11-08) kept it and made
every suspension a context switch. This document owns the task runtime of the
replacement. [Syntax](../syntax.md) §20 states the language contract; no
implementation accompanies it.

## 1. A task and its stack

A task owns a nonmoving native stack and a fixed saved-context/run-state record. It
allocates from the storage context ([buffers §3.2](buffers.md#32-allocation)) of its
executor, which every task of that executor shares: an executor runs one task at a time,
and an allocator word never contains a switch point (no wait, no budget point), so tasks
never interleave inside it and no lock is needed. A finished task leaves nothing to merge. Its stack is a pinned reservation of bytes
with a guard page, committed as it is touched; frames never move. Native words use
their ordinary call/return ABI on that stack.

**Every suspension is a context switch.** A source wait registers its operation and
switches to the scheduler; a budget point switches too. Both save the actual native
continuation (the native PC, registers and stack), including the frames of words
compiled on their own. Resuming returns to that continuation; a resumed wait reads its
completed result from its operation record. Nothing is serialized, replayed or moved.
There is no typed frame, step function or wait state.

Every residual Nua loop has a budget point in the common prepared IR. Known recursive
native-call cycles charge on entry to their compiled words. Plain non-task execution
does not schedule at these points. A header write never suspends.

## 2. Dispatch and continuation lifetime

With workers enabled, each task is assigned to an existing worker at publication, by a
scheduler-owned distribution counter. Only that executor runs it for its lifetime;
blocked plain parties wait rather than taking worker-affine activations. With no
workers, tasks run on the blocked plain executor; nested task scopes keep that
executor. Mandatory joins and worker shutdown keep executors alive until their
assigned tasks end. There are no pinned OS activations, replacement workers or
native-resume tickets.

Under the scheduler claim/lock discipline:

1. On the scheduler stack, select/unlink READY, claim RUNNING, save the executor's
   current context, install the task's context and switch to it.
2. A budget point records BUDGET and switches back. The task stays claimed until
   control is on the scheduler stack; only then is it published READY and enqueued once.
3. A source wait records WAITING with its operation and switches back. Early wakes and
   notified state are reconciled before deciding READY versus WAITING.
4. Resuming a wait performs completion, withdrawal and Slot adoption once, in the
   scheduler's wait word on the task stack, before returning to the waiting code.
   START is distinct from both resumptions.
5. DONE is published only after source completion and all owner release finish on the
   task stack, with budget service. The task then switches away permanently; its stack
   and control record are released from the scheduler stack. Registry/queue links are
   removed before detaching and waking the scope waiter.

A wake from another worker only enqueues on the assigned executor; it never resumes the
context there. No pending I/O or blocking job can own a DONE task. Every dispatch freshly
saves its scheduler continuation, so a plain executor may return to source and block
again without leaving a task aimed at an expired frame.

The scheduler/context primitive cannot recursively budget-poll under its own locks.
Long scheduler work uses bounded lock transactions. Saving/restoring Nua-selected TLS is
explicit; the entire C TLS image is not virtualized. Budget effects invalidate relevant
shared/TLS/extern observations, not the facts of private task data merely because
another task ran.

## 3. Seeded service and foreign extents

Seeded mode executes task quanta on one plain OS thread. Context switches consume no
PRNG draws. At a service round's start the ready queue becomes its finite eligible
cohort. Seeded selection removes one eligible member; yielded, newly spawned and
awakened tasks join the next round. An unserved member cannot be indefinitely displaced.
Ordinary mode uses FIFO choices in the same per-executor round protocol. Intrusive task
links avoid yield/round allocation.

Seeded `first_of` keeps its ticket-selected cyclic starting case and source-order scan.
Scheduling and ready-case draws follow execution order, not allocation addresses or OS
thread IDs. Replay is for the same program/runtime, seed, initial state and supplied
external-event trace; it does not promise unchanged schedules across runtime versions or
determinize real I/O, timers or foreign host state. Two infinite known native loops can
alternate quanta without either returning.

Opaque C `Fn`/foreign invocations enter a **foreign extent** after argument capture. No
switch happens while it is active, including during synchronous Nua callbacks beneath
the foreign caller: budget debt accumulates and is serviced at the next permitted Nua
point after the outer call returns. A word that may wait cannot be given to C as a
callback; that is refused when compiling. Direct known Nua execution is never fenced
merely because it emits C. An unknown pointer that happens to name Nua code remains
opaque unless proven.

Lifetime affinity preserves thread identity, not task-private C TLS, errno or hidden
state. External entry does not acquire an unrelated suspended task; synchronous reentry
inherits the active foreign extent. Explicit `blocking` jobs run outside the scheduler
with exclusive access to the waiting task's locals, which stay on its stack; they cannot
run a second continuation of the task. No ordinary native loop is implicitly converted
to a blocking job.

## 4. Platform mechanism and resource lifecycle

The platform facility initializes a C-ABI trampoline on supplied aligned stack storage,
switches ABI-required registers/stack/continuation/control state on the same thread, and
supplies raw reservation/guard/release mechanisms. It respects alignment, red zones,
floating-point control and shadow-stack/control-flow protections. C and JIT compilation
use the same frame/page-probing discipline: a large frame must not jump over a guard.
Fabricating a stack pointer with ordinary setjmp is not sufficient.

No allocator policy, scheduler selection or ownership walk belongs in the platform
facility. Both backends call the same Nua runtime policy and mechanisms. Switch calls are
visible control/memory effects, not eliminable pure copies. An unsupported target needs a
real port, not a hidden thread fallback claiming seeded conformance.

Before publishing a spawn, acquire and initialize the control record, context bootstrap,
stack and initial saved context, registering each acquisition before the next can fail.
Captures, Slot transfers and scope ordering are preserved. A failed spawn releases what
it acquired. A context save allocates nothing.

Each live task keeps its stack reservation until DONE, with a finite configured limit;
exhaustion is fatal in a task. Completed stacks are released. Scope join does not cancel
an infinite task, but its budget points cannot starve the finite ready cohort. A
budget-parked task is READY, not a deadlocked WAITING party.

## 5. Scope, channel and pool completion

Scopes join children before releasing channels and pools. When a value must survive a
join, it stays complete at its valid place.

Pools own stable slot storage with scope/generation/task-owner checks. Moving a Slot
handle within a task copies handle bits without changing its recorded task owner. A
successful send/give transfers to the operation or channel; receive adopts before
access. Withdrawing a losing send restores its slots once. Explicit release returns a
slot or hands it to a waiter. Scope completion makes stale handles fail without reaching
freed records. Ending a value is not a hidden Slot destructor. Unsupported Slot-in-sum
message shapes remain unsupported.

I/O keeps checked buffer access while its task waits; no simultaneous task copy mutates
that storage. Pool buffers remain out until operation completion and the source's
explicit release or send. Context switching or a blocking thread does not change
recorded Slot ownership.

## 6. Costs

Per-task stack reservations, platform context ports and worker-affinity imbalance are
real costs. Stack exhaustion can happen where a state-machine runtime would have
succeeded; it is a resource limit, not a source restriction.
