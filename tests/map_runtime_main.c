/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "map_reference.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

typedef struct Entry { uint64_t hash, key, value; } Entry;
static uint64_t hash(uint64_t key) { return (key % 13) | 1; }
static uint32_t find(const nua_map *m, uint64_t key) {
    uint32_t cursor = 0, slot;
    while ((slot = nua_map_probe(m, hash(key), &cursor)) != NUA_NONE)
        if (((Entry *)nua_map_at(m, slot))->key == key) return slot;
    return NUA_NONE;
}
static void put(nua_map *m, uint64_t key, uint64_t value) {
    uint32_t slot = find(m, key);
    if (slot != NUA_NONE) ((Entry *)nua_map_at(m, slot))->value = value;
    else { Entry entry = { hash(key), key, value }; nua_map_insert(m, &entry); }
}
static void remove_absent(void *p) { nua_map *m = p; nua_map_remove(m, find(m, 10000)); }
static void missing_bucket(void *p) { nua_map_at(p, UINT32_MAX); }
static uint32_t rng = 12345;
static uint32_t random_u32(void) { rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5; return rng; }
static void exercise(void *unused) {
    (void)unused;
    nua_gs_push(0, 32); /* preserve a preexisting owner's bytes at a nonzero base */
    memset(nua_gs(0)->data, 0xa5, 32);
    nua_map m = nua_map_new(0, 5, sizeof(Entry));
    uint64_t values[512] = { 0 };
    bool present[512] = { false };
    uint32_t round, key, count = 0;
    assert(m.base == 32 && m.live == 0 && find(&m, 1) == NUA_NONE);
    for (round = 0; round < 20000; round++) {
        key = random_u32() % 512;
        if (random_u32() & 1) {
            uint64_t value = random_u32();
            put(&m, key, value);
            if (!present[key]) count++;
            present[key] = true; values[key] = value;
        } else {
            uint32_t slot = find(&m, key);
            assert((slot != NUA_NONE) == present[key]);
            if (present[key]) { nua_map_remove(&m, slot); count--; present[key] = false; }
        }
        assert(m.live == count);
        if (round % 97 == 0) for (key = 0; key < 512; key++) {
            uint32_t slot = find(&m, key);
            assert((slot != NUA_NONE) == present[key]);
            if (present[key]) assert(((Entry *)nua_map_at(&m, slot))->value == values[key]);
        }
    }
    put(&m, 42, 100);
    put(&m, 42, 101); /* value replacement is not structural */
    assert(((Entry *)nua_map_at(&m, find(&m, 42)))->value == 101);
    assert(nua_try(remove_absent, &m) == 1); /* iteration is checked by the compiler, not here */
    uint32_t visited = 0, at;
    for (at = 0; at < m.len; at++) if (map_occupied(&m, at)) visited++;
    assert(visited == m.live);
    assert(nua_try(missing_bucket, &m) == 1);
    for (key = 0; key < 32; key++) assert(nua_gs(0)->data[key] == 0xa5);
    nua_release(m.index_stack, m.index_base);
    nua_release(m.stack, m.base);
    assert(nua_gs_top(0) == 32 && nua_gs_top(5) == 0);
}
int main(void) {
    assert(nua_try(exercise, NULL) == 0);
    nua_stacks_free(&nua_own_stacks);
    puts("map runtime: collisions, growth, deletion, reference model and traps passed");
    return 0;
}
