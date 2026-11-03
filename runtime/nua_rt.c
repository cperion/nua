/* SPDX-License-Identifier: GPL-3.0-or-later WITH GCC-exception-3.1 */
/* Nua runtime: what C alone can express. Traps return to nua_try with
 * setjmp/longjmp (a function that returns twice), and data stacks reserve
 * address space through the platform. The rest of the runtime is Nua (the .nua
 * files under runtime), compiled together. See nua_rt.h. */
#if !defined(_DEFAULT_SOURCE)
#define _DEFAULT_SOURCE
#endif
#include "nua_rt.h"
#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#if !defined(MAP_ANONYMOUS) && defined(MAP_ANON)
#define MAP_ANONYMOUS MAP_ANON
#endif
#ifndef MAP_NORESERVE
#define MAP_NORESERVE 0
#endif

/* A caller in the same process (the in-process driver) may catch the traps of
 * plain code on its own thread: nua_try runs body(env) and returns 1 if it
 * trapped. Traps inside tasks, or while a tasks scope is open, still abort:
 * other threads may be in the middle of its work. */
static __thread jmp_buf *trap_jmp;
static __thread const char *trap_what;

void nua_trap(const char *what) {
    if (trap_jmp && nua_trap_recoverable()) {
        trap_what = what;
        longjmp(*trap_jmp, 1);
    }
    fprintf(stderr, "Nua runtime check failed: %s\n", what);
    abort();
}

int nua_try(void (*body)(void *), void *env) {
    jmp_buf jb;
    jmp_buf *saved = trap_jmp;
    trap_jmp = &jb;
    if (setjmp(jb)) {
        trap_jmp = saved;
        /* the outermost call gives the thread's data stacks back */
        if (!saved) nua_stacks_clear(&nua_own_stacks);
        return 1;
    }
    body(env);
    trap_jmp = saved;
    return 0;
}

const char *nua_trap_message(void) { return trap_what; }

size_t nua_stack_bytes(bool task) {
    return task ? NUA_TASK_STACK_BYTES : NUA_THREAD_STACK_BYTES;
}

/* Address space only: pages are committed when first touched, and MAP_NORESERVE
 * keeps an unused reservation from counting against overcommit. */
uint8_t *nua_reserve(size_t bytes) {
    void *p = mmap(NULL, bytes, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    return p == MAP_FAILED ? NULL : (uint8_t *)p;
}

void nua_unreserve(uint8_t *p, size_t bytes) {
    if (p) munmap(p, bytes);
}

/* Const-pointer ABI adaptation only; byte-range composition is Nua. */
void nua_gs_write(size_t stack, size_t dst, const uint8_t *src, size_t bytes) {
    nua_gs_write_bytes(stack, dst, (uint8_t *)(uintptr_t)src, bytes);
}
