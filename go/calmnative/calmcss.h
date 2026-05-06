#ifndef CALMCSS_H
#define CALMCSS_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct calmcss_compiler calmcss_compiler;

const char *calm_version(void);

calmcss_compiler *calm_create(void);
void calm_destroy(calmcss_compiler *compiler);
void calm_clear(calmcss_compiler *compiler);

int calm_put_chunk(
    calmcss_compiler *compiler,
    const uint8_t *name,
    size_t name_len,
    const uint8_t *content,
    size_t content_len
);

size_t calm_render(calmcss_compiler *compiler);
const uint8_t *calm_result_ptr(calmcss_compiler *compiler);
size_t calm_result_len(calmcss_compiler *compiler);

size_t calm_compile(const uint8_t *input, size_t input_len, uint8_t *out, size_t out_cap);

uint8_t *calm_alloc(size_t len);
void calm_free(uint8_t *ptr, size_t len);

#ifdef __cplusplus
}
#endif

#endif
