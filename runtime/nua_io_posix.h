/* SPDX-License-Identifier: GPL-3.0-or-later WITH GCC-exception-3.1 */
/* Nua runtime: POSIX helpers shared by the I/O backends. */
#ifndef NUA_IO_POSIX_H
#define NUA_IO_POSIX_H
#include "nua_io.h"

int nua_io_nonblocking(int fd);
/* open, close, and the start of a connect complete here (1); otherwise 0: wait */
int nua_io_prepare(nua_op *op);
/* does the operation wait to write (or to read)? */
int nua_io_wants_write(const nua_op *op);
/* the descriptor is ready: perform the operation; 0 when it would still block */
int nua_io_try(nua_op *op);
/* a read or write of a regular file: handed to a blocking thread (1), since
 * such a file is always "ready" and the call blocks; otherwise 0 */
int nua_io_offload_file(nua_op *op);
/* an operation given up on (its deadline passed) releases what it holds */
void nua_io_abandon(nua_op *op);
/* Native callback ABI adapters; worker bodies are ordinary Nua. */
void nua_posix_open_close(nua_op *op);
void nua_posix_file_io(nua_op *op);
void nua_posix_submit_open_close(nua_op *op);
void nua_posix_submit_file(nua_op *op);
#endif
