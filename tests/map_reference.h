/* SPDX-License-Identifier: GPL-3.0-or-later WITH GCC-exception-3.1 */
/* Historical test oracle only. Production algorithms are lib/map.nua. */
#ifndef NUA_TEST_MAP_REFERENCE_H
#define NUA_TEST_MAP_REFERENCE_H
#include "nua_rt.h"
#include <string.h>
#define MAP_FREE (UINT64_C(1) << 63)
#define MAP_REMOVED UINT32_C(0xffffffff)
static inline uint64_t map_hash(const void *entry) {
    uint64_t h;
    memcpy(&h, entry, sizeof h);
    return h;
}
static inline uint64_t map_stored(uint64_t hash) { return (hash & ~MAP_FREE) | 1; }
static inline uint32_t *map_cells(const nua_map *m) {
    return (uint32_t *)(nua_gs(m->index_stack)->data + m->index_base);
}
/* Slots whose hash has the top bit clear hold entries; walk them with `for (slot < m->len)`. */
static inline bool map_occupied(const nua_map *m, uint32_t slot) {
    return !(map_hash(nua_map_at(m, slot)) & MAP_FREE);
}
/* Probe the index for entries with this hash; *cursor counts the cells visited. */
static inline uint32_t nua_map_probe(const nua_map *m, uint64_t hash, uint32_t *cursor) {
    hash = map_stored(hash);
    while (m->cap && *cursor < m->cap) {
        uint32_t cell = ((uint32_t)hash + (*cursor)++) & (m->cap - 1);
        uint32_t at = map_cells(m)[cell];
        if (!at) break;
        if (at == MAP_REMOVED) continue;
        if (map_hash(nua_map_at(m, at - 1)) == hash) return at - 1;
    }
    *cursor = m->cap;
    return NUA_NONE;
}
static inline size_t map_slot_bytes(const nua_map *m, uint32_t count) {
    if ((size_t)count > SIZE_MAX / m->width) nua_trap("Map is full");
    return (size_t)count * m->width;
}
static inline void map_top(const nua_map *m) {
    if (nua_gs_top(m->stack) - m->base != map_slot_bytes(m, m->len))
        nua_trap("Map grew while it was not at the top of its data stack");
    if (nua_gs_top(m->index_stack) - m->index_base != (size_t)m->cap * 4)
        nua_trap("Map index grew while it was not at the top of its data stack");
}
static inline uint32_t map_place(uint32_t *cells, uint32_t cap, uint64_t hash, uint32_t slot) {
    uint32_t cell = (uint32_t)hash & (cap - 1);
    for (;;) {
        uint32_t at = cells[cell];
        if (!at || at == MAP_REMOVED) { cells[cell] = slot + 1; return at; }
        cell = (cell + 1) & (cap - 1);
    }
}
/* Rebuild the index for `needed` entries above the old one, then move it down. */
static inline void map_rebuild(nua_map *m, uint32_t needed) {
    uint32_t cap = 8, slot;
    while ((uint64_t)cap < (uint64_t)needed * 2) {
        if (cap >= UINT32_C(0x40000000)) nua_trap("Map is full");
        cap *= 2;
    }
    size_t bytes = (size_t)cap * 4;
    size_t fresh = nua_gs_push(m->index_stack, bytes);
    nua_stack *stack = nua_gs(m->index_stack);
    uint32_t *cells = (uint32_t *)(stack->data + fresh);
    memset(cells, 0, bytes);
    for (slot = 0; slot < m->len; slot++)
        if (map_occupied(m, slot)) map_place(cells, cap, map_hash(nua_map_at(m, slot)), slot);
    memmove(stack->data + m->index_base, stack->data + fresh, bytes);
    stack->top = m->index_base + bytes;
    m->cap = cap;
    m->used = m->live;
}
static inline void nua_map_insert(nua_map *m, const void *entry) {
    uint32_t slot;
    uint64_t hash = map_stored(map_hash(entry));
    map_top(m);
    /* entry is an adapter's by-value local, never a slot address. */
    if (!m->cap || ((uint64_t)m->used + 1) * 4 > (uint64_t)m->cap * 3) map_rebuild(m, m->live + 1);
    if (m->free_head != NUA_NONE) {
        slot = m->free_head;
        m->free_head = (uint32_t)map_hash(nua_map_at(m, slot));
    } else {
        slot = m->len;
        if (slot >= UINT32_C(0xfffffffe)) nua_trap("Map is full");
        nua_gs_push(m->stack, m->width);
        m->len++;
    }
    memcpy(nua_map_at(m, slot), entry, m->width);
    memcpy(nua_map_at(m, slot), &hash, sizeof hash);
    if (!map_place(map_cells(m), m->cap, hash, slot)) m->used++;
    m->live++;
}
static inline void nua_map_remove(nua_map *m, uint32_t slot) {
    uint32_t cell, steps;
    uint64_t hash, free;
    if (slot >= m->len || !map_occupied(m, slot)) nua_trap("Map: removing an empty bucket");
    hash = map_hash(nua_map_at(m, slot));
    cell = (uint32_t)hash & (m->cap - 1);
    for (steps = 0; map_cells(m)[cell] != slot + 1; steps++) {
        if (steps >= m->cap) nua_trap("Map: index lost an entry");
        cell = (cell + 1) & (m->cap - 1);
    }
    map_cells(m)[cell] = MAP_REMOVED;
    memset(nua_map_at(m, slot), 0, m->width);
    free = MAP_FREE | m->free_head;
    memcpy(nua_map_at(m, slot), &free, sizeof free);
    m->free_head = slot;
    if (--m->live == 0) {
        nua_gs_reset(m->stack, m->base);
        m->len = 0; m->free_head = NUA_NONE;
        memset(map_cells(m), 0, (size_t)m->cap * 4);
        m->used = 0;
    }
}

static inline nua_strkey strmap_header(const nua_strmap *m, uint32_t slot) {
    nua_strkey key;
    memcpy(&key, nua_map_at(&m->entries, slot), sizeof key);
    return key;
}
static inline const uint8_t *nua_strmap_key(const nua_strmap *m, uint32_t slot) {
    nua_strkey key = strmap_header(m, slot);
    if (!key.len) return NULL;
    return nua_gs(m->arena_stack)->data + m->arena_base + key.offset;
}
static inline uint32_t nua_strmap_find(const nua_strmap *m, const uint8_t *key, uint32_t len, uint64_t hash) {
    uint32_t slot, cursor = 0;
    while ((slot = nua_map_probe(&m->entries, hash, &cursor)) != NUA_NONE) {
        nua_strkey found = strmap_header(m, slot);
        if (found.len == len && (!len || memcmp(nua_strmap_key(m, slot), key, len) == 0)) return slot;
    }
    return NUA_NONE;
}
static inline size_t strmap_append(nua_strmap *m, const uint8_t *key, uint32_t len) {
    nua_stack *s = nua_gs(m->arena_stack);
    uintptr_t from = (uintptr_t)key - (uintptr_t)s->data;
    int inside = len && s->data && from < s->top;
    size_t offset;
    if (s->top - m->arena_base != m->arena_len)
        nua_trap("Map(Str, V) grew while its arena was not at the top of its data stack");
    /* Rebuild before more arena growth when dead storage is substantial.
     * Include the pending key while old bytes still exist: it may itself be
     * a subview of an old key. No allocation occurs after offsets change. */
    if (m->dead >= 4096 && m->dead >= m->arena_len / 2) {
        size_t live = m->arena_len - m->dead, out = 0, bytes;
        uint32_t i;
        if (len > SIZE_MAX - live) nua_trap("Map(Str, V) key arena is full");
        bytes = live + len;
        size_t fresh = nua_gs_push(m->arena_stack, bytes);
        s = nua_gs(m->arena_stack);
        if (inside) key = s->data + (size_t)from;
        for (i = 0; i < m->entries.len; i++) {
            void *entry = nua_map_at(&m->entries, i);
            nua_strkey old;
            memcpy(&old, entry, sizeof old);
            if (old.hash & MAP_FREE) continue;
            if (old.len) memcpy(s->data + fresh + out, s->data + m->arena_base + old.offset, old.len);
            old.offset = out;
            out += old.len;
            memcpy(entry, &old, sizeof old);
        }
        offset = out;
        if (len) memmove(s->data + fresh + out, key, len);
        if (bytes) memmove(s->data + m->arena_base, s->data + fresh, bytes);
        s->top = m->arena_base + bytes;
        m->arena_len = bytes;
        m->dead = len; /* pending insertion not yet owned by an entry */
    } else {
        offset = m->arena_len;
        nua_gs_push(m->arena_stack, len);
        s = nua_gs(m->arena_stack);
        if (inside) key = s->data + (size_t)from;
        if (len) memmove(s->data + m->arena_base + offset, key, len);
        m->arena_len += len;
        m->dead += len;
    }
    return offset;
}
static inline void nua_strmap_insert(nua_strmap *m, const uint8_t *key, uint32_t len, void *entry, uint64_t hash) {
    nua_strkey header = { 0 };
    map_top(&m->entries);
    header.hash = map_stored(hash);
    header.len = len;
    /* Copy before table growth: key may point into an existing Chars value in
     * the table. The adapter's new value is already a by-value local. */
    header.offset = strmap_append(m, key, len);
    memcpy(entry, &header, sizeof header);
    nua_map_insert(&m->entries, entry);
    m->dead -= len;
}
static inline void nua_strmap_remove(nua_strmap *m, uint32_t slot) {
    nua_strkey key = strmap_header(m, slot);
    nua_map_remove(&m->entries, slot);
    m->dead += key.len;
    if (!m->entries.live) {
        nua_gs_reset(m->arena_stack, m->arena_base);
        m->arena_len = m->dead = 0;
    }
}


#endif
