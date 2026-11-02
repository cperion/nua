/* Harness for examples/io.nua: run with whichever backend is linked in. */
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <unistd.h>
#include <stdint.h>
#include <stdbool.h>
#include "nua_rt.h"

uint32_t pipe_roundtrip(void);
uint32_t file_roundtrip(const char *path);
uint32_t timeout_then_data(void);
uint32_t echo(uint32_t clients);
uint32_t zero_copy(uint32_t chunks);
bool refused(void);

static int failures;
#define CHECK(c) do { if (!(c)) { printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); failures++; } } while (0)

int main(void) {
    uint32_t i, want = 0;
    CHECK(pipe_roundtrip() == 12);
    for (i = 0; i < 100; i++) want += (uint8_t)(i * 7);
    /* the backends' runs are parallel: each process has its own file */
    char path[64];
    snprintf(path, sizeof path, "/tmp/nua_io_test.%ld.bin", (long)getpid());
    CHECK(file_roundtrip(path) == want);
    remove(path);
    CHECK(timeout_then_data() == 31);           /* timed out (1), then 3 bytes (30) */
    CHECK(echo(1) == 1);
    CHECK(echo(20) == 20);
    CHECK(zero_copy(50) == 50 * 16);
    CHECK(refused());
    if (failures == 0) printf("io (%s): all checks passed\n", nua_io_backend());
    return failures != 0;
}
