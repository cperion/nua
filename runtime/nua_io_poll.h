/* SPDX-License-Identifier: GPL-3.0-or-later WITH GCC-exception-3.1 */
#ifndef NUA_IO_POLL_H
#define NUA_IO_POLL_H
#include "nua_io_posix.h"
#include <pthread.h>
#include <poll.h>
typedef struct {
    pthread_mutex_t mu;
    int32_t reader, writer;
    nua_op **pending;
    uint64_t count, capacity;
} nua_poll_state;
void nua_poll_prepare(nua_poll_state *state);
void nua_poll_submit(nua_poll_state *state, nua_op *op);
void nua_poll_run(nua_poll_state *state);
#endif
