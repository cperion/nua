/* SPDX-License-Identifier: GPL-3.0-or-later WITH GCC-exception-3.1 */
#ifndef NUA_SCHEDULER_H
#define NUA_SCHEDULER_H
#include "nua_rt.h"
#include <pthread.h>

/* Shared internal layouts. Nua initializes mutexes through pthread's foreign
 * API; lock acquisition and release remain in the synchronization envelope. */
struct nua_scope {
    nua_scope *parent;
    int live;
    nua_task *waiter;
    uint32_t *chans;
    size_t nchans, cap_chans;
    uint32_t *pools;
    size_t npools, cap_pools;
};
struct queue { nua_op *head, *tail; };
struct chan_rec {
    pthread_mutex_t mu;
    uint32_t gen;
    bool live, closed;
    size_t elem;
    uint32_t cap, head, count;
    unsigned char *buf;
    struct queue recvq, sendq;
    uint32_t next_free;
};
struct pool_rec {
    pthread_mutex_t mu;
    nua_pool_meta *m;
    bool live;
    uint32_t free_head;
    size_t cap_bytes;
    uint32_t cap_slots;
    nua_scope *scope;
    struct queue takers;
    uint32_t next_free;
};

/* Internal policy state. The caller holds the owning scheduler/channel/pool
 * lock throughout each call. Words may claim atomically, but never wait,
 * unlock or wake threads. */
typedef struct { nua_task *head, *tail; uint64_t len; } nua_run_queue;
typedef struct { nua_op **data; uint64_t len, cap; } nua_timer_heap;
uint64_t nua_sched_random(uint64_t *state);
void nua_sched_push(nua_run_queue *q, nua_task *task);
nua_task *nua_sched_pop(nua_run_queue *q, uint64_t index);
nua_task *nua_sched_next(nua_run_queue *q, uint64_t *state, bool deterministic);
bool nua_timer_add(nua_timer_heap *h, nua_op *op);
void nua_timer_remove(nua_timer_heap *h, nua_op *op);
int32_t nua_op_result(nua_op *op, int32_t plain);
bool nua_task_claim(nua_task *task);
void nua_wait_enqueue(struct queue *q, nua_op *op);
void nua_wait_unlink(struct queue *q, nua_op *op);
nua_op *nua_wait_claim(struct queue *q, nua_task *self);
bool nua_wait_has(struct queue *q, nua_task *self);
int32_t nua_channel_recv(struct chan_rec *r, uint8_t *out, nua_task *self, nua_task **wake);
int32_t nua_channel_send(struct chan_rec *r, uint8_t *value, nua_task *self, nua_task **wake);
bool nua_pool_take(struct pool_rec *r, uint32_t pool, nua_slot *out, uint64_t owner);
void nua_pool_recycle(struct pool_rec *r, uint32_t index);
nua_scope *nua_scope_allocate(nua_task *task);
bool nua_scope_inside(nua_task *task, nua_scope *scope);
bool nua_scope_record(uint32_t **items, uint64_t *count, uint64_t *capacity, uint64_t initial, uint32_t index);
uint32_t nua_channel_reuse(struct chan_rec **chunks, uint32_t *head);
uint32_t nua_pool_reuse(struct pool_rec **chunks, uint32_t *head, uint32_t n, uint64_t elem);
bool nua_channel_initialize(struct chan_rec *r, uint64_t elem, uint32_t cap);
bool nua_pool_initialize(struct pool_rec *r, nua_scope *s, uint64_t elem, uint32_t n);
nua_op *nua_channel_retire(struct chan_rec *r);
nua_op *nua_pool_retire(struct pool_rec *r);
void nua_channel_recycle_record(struct chan_rec *r, uint32_t *head, uint32_t index);
void nua_pool_recycle_record(struct pool_rec *r, uint32_t *head, uint32_t index);
/* Registry calls hold registry; -1 means full, -2 allocation failure. */
int32_t nua_channel_acquire(struct chan_rec **chunks, uint32_t *head, uint32_t *count);
int32_t nua_pool_acquire(struct pool_rec **chunks, nua_pool_meta **metas, uint32_t *head,
                         uint32_t *count, uint32_t n, uint64_t elem);
nua_op *nua_channel_close_waiters(struct chan_rec *r);
/* Teardown orchestration runs without the object lock; these callbacks own
 * synchronization and wake transitions, not list traversal policy. */
void nua_task_wake(nua_task *task);
void nua_retire_channel_sync(uint32_t index);
void nua_retire_pool_sync(uint32_t index);
void nua_wait_wake(nua_op *list, int32_t plain, int32_t selected, bool clear);
void nua_scope_retire(nua_scope *scope);
void nua_timer_register(nua_op *op);
void nua_timer_cancel(nua_op *op);
uint64_t nua_select_ticket(void);
bool nua_resume_wait(nua_task *task);
struct idler { pthread_cond_t cv; struct idler *next; int listed, ready; };
struct bjob { void (*fn)(void *); void *arg; struct bjob *next; };
void nua_idler_signal(struct idler **head);
void nua_idler_enqueue(struct idler **head, struct idler *thread);
void nua_idler_remove(struct idler **head, struct idler *thread);
void nua_task_attach(nua_task **head, nua_task *task);
nua_task *nua_task_detach(nua_task **head, nua_task *task);
void nua_blocked_remove(nua_task **head, nua_task *task);
void nua_job_enqueue(struct bjob **head, struct bjob **tail, struct bjob *job);
struct bjob *nua_job_dequeue(struct bjob **head, struct bjob **tail);
bool nua_timer_fire(nua_timer_heap *heap, uint64_t now);
void nua_wake_locked(nua_task *task);
void nua_workers_init(int32_t *deterministic, uint64_t *seed);
void nua_worker_start(void);
#endif
