/* Native port of vscode-oniguruma onig.cc (Emscripten-free). */
#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct VSCodeOnigScanner VSCodeOnigScanner;

VSCodeOnigScanner *vscode_onig_scanner_create(
    const unsigned char *const *patterns,
    const int *lengths,
    int count,
    int options,
    void *syntax /* OnigSyntaxType* */
);

void vscode_onig_scanner_free(VSCodeOnigScanner *scanner);

/* Allocates result with malloc: [index, num_regs, beg0,end0,...] as int32_t. Caller frees with free(). Returns NULL on no match. */
int32_t *vscode_onig_scanner_find_next_match(
    VSCodeOnigScanner *scanner,
    int str_cache_id,
    const unsigned char *str_data,
    int str_length,
    int position_bytes,
    int options);

void vscode_onig_free_match_result(int32_t *ptr);

#ifdef __cplusplus
}
#endif
