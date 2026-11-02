/* SPDX-License-Identifier: GPL-3.0-or-later WITH GCC-exception-3.1 */
/* Nua runtime: Goose-style data stacks, managed stores, generational IDs.
 *
 * A data stack is a growable byte buffer. Every resizable value (a store, a
 * Grow array) occupies the top of the data stack the compiler assigned to it;
 * it is the only live growing value on that stack, so it can always grow in
 * place. Scopes give the space back by resetting the top.
 *
 * Stacks are addressed by index. A function receives a base index (gs_sp) and
 * uses gs_sp + k for its k-th live resizable local, so callees never share a
 * stack with a caller's live growing values. Exported functions start at 0.
 *
 * A stack never moves: it is a range of address space reserved once and
 * committed by the system as it is touched. Growth bumps the top after one
 * comparison against the reservation; an address into a stack stays valid until
 * the top is reset below it. There are no guard pages (each would cost a kernel
 * mapping per stack).
 */
#ifndef NUA_RT_H
#define NUA_RT_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

/* helpers the compiler emits per element type: not all are used by every program */
#if defined(__GNUC__) || defined(__clang__)
#define NUA_HELPER static inline __attribute__((unused))
#define NUA_NORETURN __attribute__((noreturn))
#define NUA_COLD __attribute__((cold, noreturn))
#else
#define NUA_HELPER static inline
#define NUA_NORETURN
#define NUA_COLD
#endif

typedef struct nua_stack {
    unsigned char *data;
    size_t top;
    size_t cap;         /* the bytes reserved for this stack: top never passes it */
    size_t region;      /* nonzero on the first stack of a reservation: its size */
    /* An iteration guard owns its own data stack. Resetting that stack
     * releases the borrow, including returns and residual loop exits. */
    uint32_t *map_counter;
    size_t map_guard_base;
    uint64_t map_guard_token;
} nua_stack;

/* a failed runtime check: invalid ID, misuse of a growing value */
NUA_NORETURN void nua_trap(const char *what);
/* for in-process callers: run body(env); 1 if plain code on this thread trapped
 * (nua_trap_message says why), 0 if it returned */
int nua_try(void (*body)(void *), void *env);
const char *nua_trap_message(void);
/* whether a trap here can return to nua_try: not in a task, no scope open */
int nua_trap_recoverable(void);

/* the data stacks of a thread or a task */
typedef struct nua_stackset { nua_stack *stacks; size_t n; } nua_stackset;

/* the stack set in use on this thread: a task's while a worker runs it,
 * otherwise (NULL) the thread's own */
extern __thread nua_stackset nua_own_stacks;
extern __thread nua_stackset *nua_cur_stacks;
/* the stack with index i, made on first use (out of line) */
nua_stack *nua_gs_slow(size_t i);

/* TLS selection is native; stack growth/access policy is ordinary Nua. */
nua_stackset *nua_stacks_current(void);
nua_stack *nua_gs(size_t i);
size_t nua_gs_top(size_t i);
void nua_stacks_unwind(nua_stackset *set, uint64_t mark);
void nua_stacks_clear(nua_stackset *set);
void nua_gs_write_bytes(size_t stack, size_t dst, uint8_t *src, size_t bytes);
void nua_gs_reset(size_t i, size_t top);
/* align the top of stack i for a new resizable value; returns the new top */
size_t nua_gs_begin(size_t i);
/* grow stack i by n bytes at the top; returns the offset of the new bytes */
size_t nua_gs_push(size_t i, size_t n);

/* a store token that no other store, live or dead, has had */
uint64_t nua_next_token(void);

/* the header of a managed store; slots live on its data stack */
typedef struct nua_store {
    size_t stack;       /* data stack index */
    size_t base;        /* offset of slot 0 */
    uint32_t len;       /* slots ever created */
    uint32_t live;      /* occupied slots */
    uint32_t free_head; /* first free slot, or NUA_NONE */
    uint64_t token;
} nua_store;

/* a generational ID: identifies, never owns */
typedef struct nua_id {
    uint64_t token;
    uint32_t slot;
    uint32_t gen;
} nua_id;

#define NUA_NONE UINT32_MAX
#define NUA_OCCUPIED (UINT32_MAX - 1)
#define NUA_RETIRED (UINT32_MAX - 2)

/* Reserving address space for data stacks: the platform mechanism. Placement,
 * growth and limits are Nua (lib/stacks.nua). */
#ifndef NUA_THREAD_STACK_BYTES
#define NUA_THREAD_STACK_BYTES ((size_t)64 << 30)
#endif
#ifndef NUA_TASK_STACK_BYTES
#define NUA_TASK_STACK_BYTES ((size_t)1 << 30)
#endif
/* the reservation per stack, for a task's stacks or a thread's own */
size_t nua_stack_bytes(bool task);
/* bytes of address space, committed as touched; NULL if none is available */
uint8_t *nua_reserve(size_t bytes);
void nua_unreserve(uint8_t *p, size_t bytes);

/* Data-stack byte access. */
uint8_t *nua_gs_bytes(size_t stack, size_t at, size_t bytes);
void nua_gs_copy(size_t stack, size_t dst, size_t src, size_t bytes);
void nua_gs_write(size_t stack, size_t dst, const uint8_t *src, size_t bytes);
void nua_gs_zero(size_t stack, size_t at, size_t bytes);

/* a Grow array: elements live on its data stack */
typedef struct nua_grow {
    size_t stack;
    size_t base;
    uint32_t len;
} nua_grow;

nua_store nua_store_new(size_t stack);
nua_grow nua_grow_new(size_t stack);

/* give a resizable value's space back: its stack top returns to its base */
void nua_release(size_t stack, size_t base);

/* The command line a program's main sees: a count and the NUL-terminated
 * argument strings, exactly as the process received them. */
typedef struct nua_args {
    uint32_t count;
    const char **argv;
} nua_args;

/* Checked slice access is a library word (lib/slice.nua), not a C macro. */

/* Native storage metadata. Encoding, equality, probing, growth and mutation
 * are ordinary Nua words. Bucket zero hashes denote empty slots. */
typedef struct nua_map {
    size_t stack, base, width;
    uint32_t len, cap, iterating;
} nua_map;
nua_map nua_map_new(size_t stack, size_t width);
void *nua_map_at(const nua_map *m, uint32_t slot);
/* Internal scope-owned guard, represented by an ordinary stack/base header. */
nua_grow nua_map_iter_new(size_t stack, nua_map *m);

/* Platform boundary used by Nua hashing; no hashing algorithm in this accessor. */
uint64_t nua_hash_seed_word(uint32_t index);
/* Once nua_hash_ready is set the key is final: user code reads it in place. */
extern int32_t nua_hash_ready;
extern uint64_t nua_hash_key0, nua_hash_key1;

/* StrMap entries begin with this complete key header, followed by a typed
 * value. Offsets survive arena movement; there are no retained byte pointers. */
typedef struct nua_strkey { uint64_t hash; size_t offset; uint32_t len; } nua_strkey;
typedef struct nua_strmap {
    nua_map entries;
    size_t arena_stack, arena_base, arena_len, dead;
} nua_strmap;
nua_strmap nua_strmap_new(size_t table_stack, size_t arena_stack, size_t width);

/* tasks, channels, timers (runtime/tasks.nua) ---------------------------------------------------
 * A task is a frame whose first member is a nua_task, and a step function the
 * compiler generated: it runs to its next wait and returns. A wait starts an
 * operation: it completes now (NUA_NOW), or later (NUA_PENDING), when whoever
 * completes it writes the task's result and makes it runnable. Plain code
 * waits the same way through nua_self() and blocks in nua_block(). */
typedef struct nua_scope nua_scope;
typedef struct nua_task nua_task;
typedef struct nua_chan { uint32_t idx; uint32_t gen; } nua_chan;
typedef int32_t nua_step;
typedef nua_step (*nua_step_fn)(nua_task *);

#define NUA_DONE 0
#define NUA_WAIT 1
#define NUA_YIELD 2
#define NUA_NOW 0
#define NUA_PENDING 1

typedef struct nua_op {
    nua_task *task;
    struct nua_op *next, *prev;
    void *buf;
    uint64_t deadline;
    nua_chan chan;
    int32_t kind, index, queued;
    /* I/O */
    int32_t fd;
    uint32_t len;
    int64_t offset;
    int64_t *value;
    void *backend;
    void (*job)(void *);     /* blocking work */
} nua_op;

/* operation kinds of a first_of record, and its two non-case results */
#define NUA_CASE_RECV 1
#define NUA_CASE_SEND 2
#define NUA_CASE_AFTER 3
#define NUA_CASE_TAKE 4
#define NUA_CASE_DEFAULT (-1)
#define NUA_CASE_CLOSED (-2)

struct nua_task {
    int32_t state;      /* resume point (generated code) */
    uint64_t id;        /* who owns a pool slot: never reused */
    int32_t result;     /* the last wait's result */
    int32_t budget;     /* loop rounds before the task yields */
    int32_t claimed;    /* a waiting task is completed by whoever claims it */
    int32_t run, nops, woken, blocking, depth, active;
    nua_op *ops;
    void *park;         /* a blocked plain thread's condition variable */
    nua_scope *cur_scope;   /* the innermost scope this party is in */
    nua_step_fn step;
    nua_scope *scope;
    nua_task *next, *all_prev, *all_next;
    const char *site;
    nua_stackset stacks;
};

/* the data stacks the calling thread uses (NULL: its own) */
void nua_stacks_use(nua_stackset *s);
void nua_stacks_free(nua_stackset *s);

nua_scope *nua_scope_new(nua_task *me);
int32_t nua_scope_end(nua_task *t, nua_op *ops, nua_scope *s, const char *site);
nua_task *nua_spawn(nua_scope *s, size_t frame, nua_step_fn step);
void nua_start(nua_task *t);
nua_task *nua_self(void);
void nua_block(nua_task *t);
static inline int nua_budget(nua_task *t) { return --t->budget <= 0; }

nua_chan nua_chan_new(nua_scope *s, size_t elem, uint32_t cap);
void nua_chan_close(nua_chan c);
int32_t nua_send(nua_task *t, nua_op *ops, nua_chan c, void *v, const char *site);
/* result: 1 a value, 0 closed and drained */
int32_t nua_recv(nua_task *t, nua_op *ops, nua_chan c, void *out, const char *site);
int32_t nua_sleep(nua_task *t, nua_op *ops, uint64_t ns, const char *site);
/* pools: n slots of elem bytes whose ownership moves between tasks. A slot
 * names its pool, so ownership calls need only the slot. */
typedef struct nua_pool { uint32_t idx; uint32_t gen; } nua_pool;
typedef struct nua_slot { uint32_t pool, pgen, index, gen; } nua_slot;
nua_pool nua_pool_new(nua_scope *s, size_t elem, uint32_t n);
/* wait for a free slot; *out becomes a slot the task owns */
int32_t nua_take(nua_task *t, nua_op *ops, nua_pool p, nua_slot *out, const char *site);
/* what nua_slot_at reads, published by the runtime: a pool's generation and
 * memory, and each slot's generation and owner (atomics; the memory stays for
 * as long as the record can be named) */
typedef struct nua_slot_meta { uint64_t owner; uint32_t gen, next_free; } nua_slot_meta;
typedef struct nua_pool_meta { uint32_t gen, n; size_t elem; unsigned char *data; nua_slot_meta *slots; } nua_pool_meta;
#define NUA_POOL_CHUNK 256u
#define NUA_POOL_CHUNKS 4096u
extern nua_pool_meta **nua_pool_metas;     /* NUA_POOL_CHUNKS pointers, made when the runtime starts */
/* a failed slot check: names what failed, then traps */
NUA_COLD void nua_slot_fault(nua_task *me, nua_slot s);

/* the slot's contents, checked at every access: this party owns the slot.
 * Inline and lock-free; only a failure leaves the fast path. */
static inline void *nua_slot_at(nua_task *me, nua_slot s) {
    nua_pool_meta *chunk = nua_pool_metas && s.pool / NUA_POOL_CHUNK < NUA_POOL_CHUNKS
        ? nua_pool_metas[s.pool / NUA_POOL_CHUNK] : NULL;
    if (chunk && s.pgen) {
        nua_pool_meta *m = &chunk[s.pool % NUA_POOL_CHUNK];
        if (__atomic_load_n(&m->gen, __ATOMIC_ACQUIRE) == s.pgen && s.index < m->n) {
            nua_slot_meta *sl = &m->slots[s.index];
            if (__atomic_load_n(&sl->gen, __ATOMIC_ACQUIRE) == s.gen
                && __atomic_load_n(&sl->owner, __ATOMIC_ACQUIRE) == me->id)
                return m->data + (size_t)s.index * m->elem;
        }
    }
    nua_slot_fault(me, s);
}
void nua_slot_release(nua_task *me, nua_slot s);
/* a send moves a slot: its owner gives it before, the receiver adopts it after */
void nua_slot_give(nua_task *me, nua_slot s);
void nua_slot_adopt(nua_task *me, nua_slot s);

/* I/O by completion (syntax §20.7). The result is NUA_IO_DONE, NUA_IO_FAILED or
 * NUA_IO_TIMED_OUT; *value receives the count or descriptor when done, the
 * system's error code when failed. A deadline of 0 is none; an offset of -1
 * is the descriptor's own position. */
#define NUA_IO_DONE 0
#define NUA_IO_FAILED 1
#define NUA_IO_TIMED_OUT 2
int32_t nua_io_read(nua_task *t, nua_op *ops, int32_t fd, void *buf, uint32_t n, int64_t offset, uint64_t deadline,
                    int64_t *value, const char *site);
int32_t nua_io_write(nua_task *t, nua_op *ops, int32_t fd, void *buf, uint32_t n, int64_t offset,
                     uint64_t deadline, int64_t *value, const char *site);
int32_t nua_io_accept(nua_task *t, nua_op *ops, int32_t fd, uint64_t deadline, int64_t *value, const char *site);
int32_t nua_io_connect(nua_task *t, nua_op *ops, uint32_t host, uint32_t port, uint64_t deadline, int64_t *value,
                       const char *site);
int32_t nua_io_open(nua_task *t, nua_op *ops, const char *path, int32_t flags, uint32_t mode, int64_t *value,
                    const char *site);
int32_t nua_io_close(nua_task *t, nua_op *ops, int32_t fd, int64_t *value, const char *site);
/* setup that never waits: 0 done, 1 failed (*value: the error) */
int32_t nua_io_pipe(int32_t *reader, int32_t *writer, int64_t *value);
int32_t nua_io_listen(uint32_t host, uint32_t port, int64_t *value);
uint32_t nua_io_local_port(int32_t fd);
/* run job(env) on a blocking thread while the task waits: for calls into C
 * that may block. The task's data stacks travel with it. */
int32_t nua_blocking(nua_task *t, nua_op *ops, void (*job)(void *), void *env, const char *site);

/* the backend linked in: "poll", "io_uring" or "kqueue" */
const char *nua_io_backend(void);

/* first_of is sequenced where it is written (lib/select.nua): the program fills the
 * operation records, tries each case once through these, and arms them all when none
 * is ready. Each try is one locked transaction on one channel or pool: 1 it
 * happened, 0 not ready (a receive also gives -1: closed and drained). */
int32_t nua_poll_recv(nua_task *t, nua_op *op);
int32_t nua_poll_send(nua_task *t, nua_op *op);
int32_t nua_poll_take(nua_task *t, nua_op *op);
/* wait on every record; NUA_NOW when one was ready after all, NUA_PENDING otherwise */
int32_t nua_select_arm(nua_task *t, nua_op *ops, int32_t n, const char *site);
/* where the scan starts, so no case is always favoured */
uint64_t nua_select_ticket(void);
uint64_t nua_now_ns(void);

#endif
