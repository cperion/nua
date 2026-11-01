/* Independent models for lock-scoped Nua channel/pool policy. */
#include "nua_scheduler.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static void queues(void) {
    struct queue q = {0};
    nua_task tasks[4] = {{0}};
    nua_op ops[4] = {{0}};
    for (unsigned i = 0; i < 4; ++i) {
        ops[i].task = &tasks[i]; nua_wait_enqueue(&q, &ops[i]);
        assert(ops[i].queued && q.tail == &ops[i]);
    }
    tasks[1].claimed = 1; /* losing first_of record must be unlinked */
    assert(nua_wait_claim(&q, &tasks[0]) == &ops[2]);
    assert(q.head == &ops[0] && ops[0].next == &ops[3]);
    assert(!ops[1].queued && !ops[2].queued && tasks[2].claimed);
    nua_wait_unlink(&q, &ops[3]);
    nua_wait_unlink(&q, &ops[3]);
    assert(!nua_wait_has(&q, &tasks[0]));
    assert(!nua_wait_claim(&q, &tasks[0]));
    assert(nua_wait_claim(&q, NULL) == &ops[0]);
    assert(!q.head && !q.tail);
    assert(!nua_task_claim(&tasks[0]));
}
static void channels(void) {
    struct chan_rec r = {0};
    uint32_t buffer[3], model[3], n = 0, out = 0;
    nua_task self = {0}, peer = {0}, *wake = NULL;
    r.elem = sizeof out; r.cap = 3; r.buf = (uint8_t *)buffer;
    for (unsigned i = 0; i < 2000; ++i) {
        uint32_t value = i * 17;
        if (i % 5 < 3) {
            int got = nua_channel_send(&r, (uint8_t *)&value, &self, &wake);
            assert(got == (n < 3));
            if (got) model[n++] = value;
        } else {
            int got = nua_channel_recv(&r, (uint8_t *)&out, &self, &wake);
            assert(got == (n > 0));
            if (got) {
                assert(out == model[0]);
                --n; memmove(model, model + 1, n * sizeof *model);
            }
        }
        assert(r.count == n && !wake);
    }
    while (n) {
        assert(nua_channel_recv(&r, (uint8_t *)&out, &self, &wake) == 1);
        assert(out == model[0]); --n; memmove(model, model + 1, n * sizeof *model);
    }
    /* A buffered receive refills the vacated slot from a waiting sender. */
    uint32_t value = 42, pending = 99;
    assert(nua_channel_send(&r, (uint8_t *)&value, &self, &wake));
    nua_op op = {0}; op.task = &peer; op.buf = &pending; op.index = 7;
    nua_wait_enqueue(&r.sendq, &op);
    assert(nua_channel_recv(&r, (uint8_t *)&out, &self, &wake) == 1);
    assert(out == 42 && wake == &peer && peer.result == 7 && r.count == 1);
    assert(nua_channel_recv(&r, (uint8_t *)&out, &self, &wake) == 1 && out == 99);
    /* Unbuffered rendezvous, including plain receive result and no self-match. */
    r.cap = 0; peer.claimed = 0; op.index = -1; op.buf = &out;
    nua_wait_enqueue(&r.recvq, &op);
    assert(!nua_channel_send(&r, (uint8_t *)&value, &peer, &wake));
    assert(nua_channel_send(&r, (uint8_t *)&value, &self, &wake));
    assert(out == value && wake == &peer && peer.result == 1);
    peer.claimed = 0; op.buf = &pending;
    nua_wait_enqueue(&r.sendq, &op);
    assert(nua_channel_recv(&r, (uint8_t *)&out, &self, &wake) == 1);
    assert(out == pending && peer.result == 0 && wake == &peer);
    r.closed = true;
    assert(nua_channel_recv(&r, (uint8_t *)&out, &self, &wake) == -1);
}
static void pools(void) {
    nua_slot_meta slots[2] = {{0, 9, 1}, {0, UINT32_MAX, NUA_NONE}};
    nua_pool_meta meta = {0}; meta.gen = 23; meta.slots = slots;
    struct pool_rec pool = {0}; pool.m = &meta;
    nua_slot a, b;
    assert(nua_pool_take(&pool, 4, &a, 123));
    assert(a.pool == 4 && a.pgen == 23 && a.index == 0 && a.gen == 9 && slots[0].owner == 123);
    assert(nua_pool_take(&pool, 4, &b, 124) && b.index == 1);
    assert(!nua_pool_take(&pool, 4, &b, 125));
    nua_pool_recycle(&pool, 1);
    assert(slots[1].gen == 1 && slots[1].owner == 0 && pool.free_head == 1);
    nua_pool_recycle(&pool, 0);
    assert(slots[0].gen == 10 && slots[0].next_free == 1);
    assert(nua_pool_take(&pool, 4, &a, 126) && a.index == 0 && a.gen == 10);
    assert(nua_pool_take(&pool, 4, &b, 127) && b.index == 1 && b.gen == 1);
}
int main(void) {
    queues(); channels(); pools();
    puts("channel/pool policy: cancellation, self exclusion, ring model, handoff, generations passed");
    return 0;
}
