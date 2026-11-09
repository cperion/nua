/* The platform mechanisms of the replacement compiler (next/nua/compiler/platform.mua): only
 * what C must supply. Allocation policy, size classes and free lists are Nua code over these.
 * Every function is static: each compiled unit carries its own copy. The ledger counts mapped
 * bytes independently of the Nua allocator, for tests to check it against. */
#ifndef NUA_PLATFORM_H
#define NUA_PLATFORM_H

#ifndef _DEFAULT_SOURCE
#define _DEFAULT_SOURCE
#endif
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

static uint64_t nua_ledger_bytes;

static inline void nua_fatal_trap(uint8_t *message, uint64_t length) {
    fprintf(stderr, "nua: %.*s\n", (int)length, (const char *)message);
    abort();
}

static inline uint8_t *nua_map_pages(uint64_t bytes) {
    void *pages = mmap(0, (size_t)bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (pages == MAP_FAILED) {
        fprintf(stderr, "nua: out of memory mapping %llu bytes\n", (unsigned long long)bytes);
        abort();
    }
    nua_ledger_bytes += bytes;
    return (uint8_t *)pages;
}

static inline void nua_unmap_pages(uint8_t *pages, uint64_t bytes) {
    munmap(pages, (size_t)bytes);
    nua_ledger_bytes -= bytes;
}

static inline void nua_move_bytes(uint8_t *target, uint8_t *source, uint64_t bytes) {
    memmove(target, source, (size_t)bytes);
}

#define NUA_CONTEXT_BYTES 256
static inline uint8_t *nua_storage_context(void) {
    static _Thread_local uint64_t context[NUA_CONTEXT_BYTES / 8];
    return (uint8_t *)context;
}

static inline uint64_t nua_ledger_mapped_bytes(void) { return nua_ledger_bytes; }

/* the process's hash key, read from the system once */
#include <sys/random.h>
static inline uint64_t nua_hash_seed(uint64_t which) {
    static uint64_t seed[2];
    static _Atomic int ready;
    if (!ready) {
        if (getrandom(seed, sizeof seed, 0) != (ssize_t)sizeof seed) {
            fprintf(stderr, "nua: no random seed for hashing\n");
            abort();
        }
        ready = 1;
    }
    return seed[which & 1];
}

/* a store's token: from one counter, never reused, never 0 (syntax §9.9) */
static inline uint64_t nua_next_store_token(void) {
    static _Atomic uint64_t counter;
    return ++counter;
}

/* the bits of a float as an integer and back (Nua's reinterpret of floats) */
#define NUA_REINTERPRET(from, to) \
    static inline to nua_reinterpret_##from##_##to(from value) { to result; memcpy(&result, &value, sizeof result); return result; }
NUA_REINTERPRET(float, uint32_t)
NUA_REINTERPRET(float, int32_t)
NUA_REINTERPRET(uint32_t, float)
NUA_REINTERPRET(int32_t, float)
NUA_REINTERPRET(double, uint64_t)
NUA_REINTERPRET(double, int64_t)
NUA_REINTERPRET(uint64_t, double)
NUA_REINTERPRET(int64_t, double)

#endif
