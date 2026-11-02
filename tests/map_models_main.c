#include "nua_rt.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
bool map_model(uint32_t rounds, uint32_t width, uint32_t limit);
bool strmap_model(uint32_t rounds, uint32_t width, uint32_t limit);
uint32_t map_table_alias(uint32_t count);
uint32_t map_eager_ensure(void);
uint32_t map_arena_alias(uint32_t count, uint32_t width);
typedef struct Str { uint8_t *ptr; uint64_t len; } Str;
uint64_t map_model_extent(nua_strmap *m) { return m->arena_len; }
Str map_model_arena_alias(nua_strmap *m) {
    uint32_t i;
    for (i = 0; i < m->entries.cap; i++) {
        nua_strkey key;
        memcpy(&key, nua_map_at(&m->entries, i), sizeof key);
        if (key.hash && key.len > 1) {
            Str view = { nua_gs(m->arena_stack)->data + m->arena_base + key.offset + 1, key.len - 1 };
            return view;
        }
    }
    assert(0); Str empty = { NULL, 0 }; return empty;
}
static uint32_t calls;
uint32_t map_model_bump(void) { return ++calls; }
#ifndef NUA_MAP_MODEL_SUPPORT_ONLY
int main(void) {
    assert(map_model(20000, 80, 128));
    assert(strmap_model(20000, 80, 128));
    assert(map_table_alias(6) == 10);
    assert(map_arena_alias(128, 96) == 1064);
    assert(map_eager_ensure() == 1 && calls == 2);
    nua_stacks_free(&nua_own_stacks);
    puts("Nua maps: 40000 model operations, arena churn, table alias and eager ensure passed");
    return 0;
}
#endif
