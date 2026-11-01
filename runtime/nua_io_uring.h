/* SPDX-License-Identifier: GPL-3.0-or-later WITH GCC-exception-3.1 */
#ifndef NUA_IO_URING_H
#define NUA_IO_URING_H
#include "nua_io_posix.h"
#include <pthread.h>
#include <linux/io_uring.h>
#include <netinet/in.h>
typedef struct {
    pthread_mutex_t mu;
    int32_t fd;
    uint32_t *sq_head, *sq_tail, *sq_mask, *sq_array, sq_entries;
    uint32_t *cq_head, *cq_tail, *cq_mask;
    struct io_uring_sqe *sqes;
    struct io_uring_cqe *cqes;
} nua_uring_state;
typedef struct { struct __kernel_timespec ts; struct sockaddr_in addr; } nua_uring_extra;
int32_t nua_uring_enter(nua_uring_state *, uint32_t submit, uint32_t wait, uint32_t flags);
/* Kernel ABI marshalling: io_uring encodes addresses in integer fields. */
void nua_uring_address(struct io_uring_sqe *, void *);
void nua_uring_user(struct io_uring_sqe *, nua_op *);
nua_op *nua_uring_decode(uint64_t);
void nua_uring_submit(nua_uring_state *, nua_op *);
void nua_uring_run(nua_uring_state *);
#endif
