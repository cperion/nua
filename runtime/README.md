# Runtime implementation

Runtime policy is ordinary Nua, built from [the runtime entry](scheduler.nua).

- [Scheduler words](scheduler.nua): replayable randomness, run queues, timer heaps,
  waiters, buffered/rendezvous transfers and pool free lists/generations.
- [Lifecycle](lifecycle.nua): scopes, owned-record vectors, registry chunk growth,
  mutex initialization, reuse, metadata linkage, retirement and teardown.
- [Protocol](protocol.nua): channel/slot validation and ownership, first-of
  scan/arm/withdraw/retry, blocking-operation preparation and resumption.
- [Bookkeeping](bookkeeping.nua): idler/task/job lists, timer firing and worker
  configuration.
- [I/O](io.nua) and [POSIX](posix.nua): operation construction/completion, syscall
  composition, retries, socket setup and failure cleanup.
- [Poll](poll.nua), [kqueue](kqueue.nua) and [io_uring](uring.nua): backend queue,
  deadline, submission and completion policy, including the event loops.
- [Tasks](tasks.nua): workers, plain-thread waits, wake transitions, scopes, the
  channel and pool registries, timers, blocking threads and the I/O accounting,
  under the scheduler lock, with the thread bodies passed to `pthread_create` as
  `fnptr` words. Its state is native globals (`global`, syntax §21), thread-local
  where it belongs to a thread.
- [Select](../lib/select.nua): `first_of` at its call site. The program fills the
  operation records and a shared function per shape of select makes one attempt per
  case through `nua_poll_recv`/`send`/`take`, then arms them all through `nua_select_arm`.
- [Process](process.nua): the data-stack set a thread uses (thread-local
  `nua_own_stacks` and `nua_cur_stacks`), store tokens and the hash key.
- [Backend](backend.nua): the poller thread and submission entry of the poll and
  kqueue backends.
- [Stacks](../lib/stacks.nua) and [storage layout](../lib/storage_layout.nua):
  data-stack growth/access/unwinding and Store, Grow, Id, Map and StrMap record
  access. The runtime entry exports both sets, so programs and the runtime share
  one implementation.

Nua modules call each other's words directly where no synchronization boundary
intervenes. Exports provide the native runtime ABI, not alternate algorithms.
The owning mutex stays held across each transaction. Unlock-before-trap,
claim-before-transfer, successful-path adoption, capture-next-before-wake and
atomic memory orders are preserved. Protocol words can explicitly lock, unlock
and wake; leaf queue/heap/transfer words rely on their caller's transaction.

C retains `nua_trap` and `nua_try` (`setjmp`/`longjmp` return twice) and
`nua_reserve`/`nua_unreserve`, which map the address space of data stacks (`mmap`
signals failure with `MAP_FAILED`, an address Nua cannot compare), in [nua_rt.c](nua_rt.c). io_uring additionally
retains Linux setup/mmap and integer-address kernel ABI marshalling in
[nua_io_uring.c](nua_io_uring.c). The language deliberately offers no integer-pointer
conversion. Nothing else in the runtime is C: locks, parking, wake-ups, clock reads,
thread creation and the deadlock report are Nua calling libc and pthreads.

A program is built with the runtime: its words are made lazily, only those the
program names (and what they name) are emitted, and `runtime/nua_rt.c` (plus
`runtime/nua_io_uring.c` for io_uring) is all that links beside the program's C.
`NUA_IO=poll` (default), `uring` or `kqueue` selects the backend when the program is
built. C that calls runtime words the program never names asks for them with
`--keep-runtime`. Generated C enables POSIX feature declarations before system headers.

`make runtime` compiles the *shared* runtime unit and prints its generated C path. It is
what the in-process backend and libgccjit objects link, because they need one copy of the
scheduler's state; it lives under `NUA_CACHE` or `build/runtime`, never as checked-in
source.

[The shared builder](../nua/runtime_build.lua) also accepts `source(backend)`.
It runs the frontend in a separate process, preserving an active compilation's
state, and caches independently per backend. Native cache identity includes the
generated policy and internal layout headers. There is no handwritten fallback.

`make test-scheduler` exercises C and libgccjit policy objects, recursive layouts,
independent queue/heap/channel/pool/lifecycle models and threaded/seeded channel
and poll-I/O integration. It requires libgccjit. The normal test suite also
exercises backend integrations and the existing sanitizer paths. Missing platform
headers or kernel support are limitations, not passing backend checks.

[The architecture](../docs/architecture.md#15-what-stays-in-c-and-lua-and-why) tracks
compiler-side library composition and the external mechanisms separately from this
runtime rewrite.
