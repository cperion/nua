/* SPDX-License-Identifier: GPL-3.0-or-later WITH GCC-exception-3.1 */
/* Nua runtime: what C alone can express. Traps return to nua_try with
 * setjmp/longjmp (a function that returns twice), and a data-stack source
 * pointer is located by comparing addresses. The rest of the runtime is Nua
 * (the .nua files under runtime), compiled together. See nua_rt.h. */
#include "nua_rt.h"
#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>

/* A caller in the same process (the in-process driver) may catch the traps of
 * plain code on its own thread: nua_try runs body(env) and returns 1 if it
 * trapped. Traps inside tasks, or while a tasks scope is open, still abort:
 * other threads may be in the middle of its work. */
static __thread jmp_buf *trap_jmp;
static __thread const char *trap_what;
static __thread uint64_t trap_map_mark;

void nua_trap(const char *what) {
    if (trap_jmp && nua_trap_recoverable()) {
        trap_what = what;
        /* Release before longjmp, while the map headers in the unwound native
         * frames are still alive. An enclosing try's guards remain active. */
        nua_stacks_unwind(&nua_own_stacks, trap_map_mark);
        longjmp(*trap_jmp, 1);
    }
    fprintf(stderr, "Nua runtime check failed: %s\n", what);
    abort();
}

int nua_try(void (*body)(void *), void *env) {
    jmp_buf jb;
    jmp_buf *saved = trap_jmp;
    uint64_t saved_mark = trap_map_mark;
    trap_map_mark = nua_next_token();
    trap_jmp = &jb;
    if (setjmp(jb)) {
        trap_jmp = saved;
        trap_map_mark = saved_mark;
        /* the outermost call gives the thread's data stacks back */
        if (!saved) nua_stacks_clear(&nua_own_stacks);
        return 1;
    }
    body(env);
    trap_jmp = saved;
    trap_map_mark = saved_mark;
    return 0;
}

const char *nua_trap_message(void) { return trap_what; }

/* The offset of p in data stack `stack`, or SIZE_MAX if p is not inside it:
 * Nua has no pointer subtraction. */
size_t nua_gs_pin(size_t stack, const uint8_t *p, size_t bytes) {
    nua_stack *s = nua_gs(stack);
    uintptr_t at = (uintptr_t)p - (uintptr_t)s->data;
    if (!bytes || !s->data || at >= s->top) return SIZE_MAX;
    if (bytes > s->top - at) nua_trap("data stack source out of range");
    return (size_t)at;
}
/* Const-pointer ABI adaptation only; byte-range composition is Nua. */
void nua_gs_write(size_t stack, size_t dst, const uint8_t *src, size_t bytes) {
    nua_gs_write_bytes(stack, dst, (uint8_t *)(uintptr_t)src, bytes);
}
