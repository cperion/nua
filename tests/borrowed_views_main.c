#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

uint32_t foreign_sum(uint8_t *pointer, uint32_t length);
uint32_t snapshot_length(uint8_t *pointer, uint32_t *length);
uint32_t copy_fixed_release(uint8_t *pointer, uint32_t length);
uint32_t copy_text_release(uint8_t *pointer, uint32_t length);
uint32_t branch_length(uint8_t *pointer, uint32_t length, bool flag);
uint32_t outcome_length(uint8_t *pointer, uint32_t length, bool flag);
uint32_t tail_length(uint8_t *pointer, uint32_t length, uint32_t count);
uint32_t nested_length(uint8_t *first, uint8_t *second, uint32_t length);

static int failures;
#define CHECK(c) do { if (!(c)) { printf("FAIL borrowed views:%d: %s\n", __LINE__, #c); failures++; } } while (0)

static uint8_t *source(void) {
    static const uint8_t bytes[] = { 65, 0, 66, 67 };
    uint8_t *p = malloc(sizeof bytes);
    if (!p) abort();
    memcpy(p, bytes, sizeof bytes);
    return p;
}

int main(void) {
    uint8_t *p = source();
    uint32_t length = 4;
    CHECK(foreign_sum(p, 4) == 198);
    CHECK(snapshot_length(p, &length) == 4 && length == 0);
    CHECK(branch_length(p, 4, false) == 4);
    CHECK(branch_length(p, 4, true) == 0);
    CHECK(outcome_length(p, 4, true) == 4);
    CHECK(outcome_length(p, 4, false) == 0);
    CHECK(tail_length(p, 4, 100) == 4);
    CHECK(nested_length(p, p, 4) == 4);
    free(p);
    /* Each callee ends its loan, frees this source, then reads the owned copy. */
    CHECK(copy_fixed_release(source(), 4) == 198);
    CHECK(copy_text_release(source(), 4) == 198);
    CHECK(copy_fixed_release(source(), 0) == 0);
    CHECK(copy_text_release(source(), 0) == 0);
    if (failures == 0) puts("borrowed_views: ok");
    return failures != 0;
}
