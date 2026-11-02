/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Text append must accept unrelated sources and its own stack's bytes; data
 * stacks never move, so a large append leaves every address in place. */
#include "text_reference.h"
#include <assert.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

static void expect(const nua_grow *g, const char *text) {
    assert(g->len == strlen(text));
    assert(memcmp(nua_gs(g->stack)->data + g->base, text, g->len) == 0);
}

int main(void) {
    nua_stackset stacks = { 0 };
    nua_stacks_use(&stacks);
    nua_grow text = nua_grow_new(0);
    nua_grow_write_bytes(&text, NULL, 0);
    assert(text.len == 0);
    assert(nua_gs(0)->data != NULL);
    /* Integer/Bool formatting now lives in Nua (formatting_main.c tests it).
     * The remaining float helper still supplies an unrelated stack buffer. */
    nua_grow_write_bytes(&text, (const uint8_t *)"unit = ", 7);
    nua_grow_write_f64(&text, 1.5);
    expect(&text, "unit = 1.5");
    nua_grow_clear(&text);
    uint8_t stack_bytes[] = { 's', 't', 'a', 'c', 'k' };
    uint8_t *heap_bytes = malloc(4);
    assert(heap_bytes);
    memcpy(heap_bytes, "heap", 4);
    nua_grow_write_bytes(&text, stack_bytes, sizeof stack_bytes);
    nua_grow_write_bytes(&text, heap_bytes, 4);
    expect(&text, "stackheap");
    free(heap_bytes);

    /* A nonzero base catches offsets accidentally measured from the Text rather
     * than from the entire stack. The append reads bytes of the Text itself. */
    nua_gs_push(1, 32);
    memset(nua_gs(1)->data, 0xa5, 32);
    nua_grow alias = nua_grow_new(1);
    assert(alias.base == 32);
    uint8_t seed[257];
    for (size_t i = 0; i < sizeof seed; ++i) seed[i] = (uint8_t)(i * 17u);
    nua_grow_write_bytes(&alias, seed, sizeof seed);
    size_t before_cap = nua_gs(1)->cap;
    uintptr_t before_address = (uintptr_t)nua_gs(1)->data;
    uint32_t appended = (uint32_t)sizeof seed - 7;
    nua_grow_write_bytes(&alias, nua_gs(1)->data + alias.base + 7, appended);
    assert(nua_gs(1)->cap == before_cap);
    assert((uintptr_t)nua_gs(1)->data == before_address);
    assert(alias.len == sizeof seed + appended);
    assert(memcmp(nua_gs(1)->data + alias.base, seed, sizeof seed) == 0);
    assert(memcmp(nua_gs(1)->data + alias.base + sizeof seed, seed + 7, appended) == 0);
    for (size_t i = 0; i < 32; ++i) assert(nua_gs(1)->data[i] == 0xa5);
    printf("Text runtime: ok (reservation %zu, stack never moved)\n", before_cap);
    nua_stacks_use(NULL);
    nua_stacks_free(&stacks);
    return 0;
}
