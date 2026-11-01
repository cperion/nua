/* SPDX-License-Identifier: GPL-3.0-or-later WITH GCC-exception-3.1 */
#ifndef NUA_IO_KQUEUE_H
#define NUA_IO_KQUEUE_H
#include "nua_io_posix.h"
#include <pthread.h>
#include <sys/event.h>
#include <time.h>
typedef struct { nua_op *head, *tail; } nua_fd_waiters;
typedef struct { nua_fd_waiters read, write; } nua_fd_queue;
typedef struct {
    pthread_mutex_t mu;
    int32_t kq;
    nua_op *incoming;
    nua_fd_queue *fds;
    uint64_t capacity;
} nua_kqueue_state;
void nua_kqueue_prepare(nua_kqueue_state *state);
void nua_kqueue_submit(nua_kqueue_state *state, nua_op *op);
void nua_kqueue_run(nua_kqueue_state *state);
#endif
