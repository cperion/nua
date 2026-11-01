/* SPDX-License-Identifier: GPL-3.0-or-later WITH GCC-exception-3.1 */
/* Historical oracle only. Production text policy is in lib/storage.nua and lib/format.nua. */
#ifndef NUA_TEXT_REFERENCE_H
#define NUA_TEXT_REFERENCE_H
#include "nua_rt.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static inline void nua_grow_write_bytes(nua_grow *g, const uint8_t *p, uint32_t n) {
    nua_stack *s = nua_gs(g->stack);
    size_t at, from = 0;
    uintptr_t offset;
    int inside;
    if (n == 0) return;
    if (s->top != g->base + (size_t)g->len) nua_trap("Text grew while it was not at the top of its data stack");
    if (n > UINT32_MAX - g->len) nua_trap("Text is full");
    /* The supported flat-address targets preserve addresses in uintptr_t.
     * Compare integers: p may name an unrelated literal or formatting buffer,
     * so ordering/subtracting the pointers themselves would be undefined.
     * If it names this stack, save its offset before growth can move it. */
    offset = (uintptr_t)p - (uintptr_t)s->data;
    inside = s->data && offset < s->top;
    if (inside) from = (size_t)offset;
    at = nua_gs_push(g->stack, n);
    s = nua_gs(g->stack);
    if (inside) p = s->data + from;
    memmove(s->data + at, p, n);
    g->len += n;
}

static inline uint32_t nua_format_f64(char *buf, double v) {
    int p;
    if (v != v) { memcpy(buf, "nan", 4); return 3; }
    if (v == 1.0 / 0.0) { memcpy(buf, "inf", 4); return 3; }
    if (v == -1.0 / 0.0) { memcpy(buf, "-inf", 5); return 4; }
    for (p = 1; p <= 17; p++) {
        snprintf(buf, 32, "%.*g", p, v);
        if (strtod(buf, NULL) == v) break;
    }
    return (uint32_t)strlen(buf);
}

static inline void nua_grow_write_f64(nua_grow *g, double v) {
    char buf[32];
    uint32_t n = nua_format_f64(buf, v);
    nua_grow_write_bytes(g, (const uint8_t *)buf, n);
}

static inline void nua_grow_clear(nua_grow *g) {
    nua_gs_reset(g->stack, g->base);
    g->len = 0;
}

#endif
