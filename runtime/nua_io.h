/* SPDX-License-Identifier: GPL-3.0-or-later WITH GCC-exception-3.1 */
/* Nua runtime: the interface between the scheduler and an I/O backend.
 *
 * A backend file (nua_io_poll.c, nua_io_uring.c or nua_io_kqueue.c) is linked
 * with the generated runtime unit. The scheduler hands it operation records; the backend
 * calls nua_io_complete exactly once per record, from any thread. */
#ifndef NUA_IO_H
#define NUA_IO_H
#include "nua_rt.h"

enum { NUA_K_READ = 20, NUA_K_WRITE, NUA_K_ACCEPT, NUA_K_CONNECT, NUA_K_OPEN, NUA_K_CLOSE, NUA_K_BLOCKING };

/* run fn(arg) on a blocking thread (for a backend's own blocking work, such as
 * regular-file I/O on a readiness backend) */
void nua_run_blocking(void (*fn)(void *), void *arg);

/* start an operation; it completes later (or at once) through nua_io_complete */
void nua_backend_submit(nua_op *op);
/* provided by the scheduler */
void nua_io_complete(nua_op *op, int32_t status, int64_t value);
uint64_t nua_now_ns(void);

/* Submission/completion accounting is synchronized by the scheduler. */
void nua_io_publish(nua_op *op);
void nua_io_notify(nua_task *task);
/* deadline of an operation: absolute monotonic nanoseconds, or 0 */
#endif
