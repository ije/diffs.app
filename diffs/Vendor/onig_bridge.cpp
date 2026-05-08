/* Native port of to-port/vscode-oniguruma/onig.cc (no Emscripten). */
#include "onig_bridge.h"

#include <cstdlib>
#include <cstring>

#include "oniguruma.h"

extern "C" {

static int last_onig_status = 0;
static OnigErrorInfo last_onig_error_info;

typedef struct OnigRegExp_ {
    unsigned char *str_data;
    int str_length;
    regex_t *regex;
    OnigRegion *region;
    bool has_g_anchor;
    int last_search_str_cache_id;
    int last_search_position;
    OnigOptionType last_search_onig_option;
    bool last_search_matched;
} OnigRegExp;

struct VSCodeOnigScanner {
    OnigRegSet *rset;
    OnigRegExp **regexes;
    int count;
};

#define MAX_REGIONS 1000

static bool has_g_anchor(const unsigned char *str, int len) {
    for (int pos = 0; pos < len; pos++) {
        if (str[pos] == '\\' && pos + 1 < len && str[pos + 1] == 'G') {
            return true;
        }
    }
    return false;
}

static int32_t *encode_onig_region_heap(OnigRegion *result, int index) {
    if (result == nullptr || result->num_regs > MAX_REGIONS) {
        return nullptr;
    }
    int32_t n = result->num_regs;
    int32_t *buf = (int32_t *)malloc(sizeof(int32_t) * (2 + 2 * n));
    if (!buf) {
        return nullptr;
    }
    buf[0] = index;
    buf[1] = n;
    for (int i = 0; i < n; i++) {
        buf[2 + 2 * i] = (int32_t)result->beg[i];
        buf[2 + 2 * i + 1] = (int32_t)result->end[i];
    }
    return buf;
}

static OnigRegExp *create_onig_reg_exp(const unsigned char *data, int length, int options, OnigSyntaxType *syntax) {
    regex_t *regex = nullptr;
    last_onig_status = onig_new(&regex, (UChar *)data, (UChar *)(data + length), (OnigOptionType)options, ONIG_ENCODING_UTF8,
                               syntax, &last_onig_error_info);
    if (last_onig_status != ONIG_NORMAL) {
        return nullptr;
    }
    OnigRegExp *result = (OnigRegExp *)malloc(sizeof(OnigRegExp));
    result->str_length = length;
    result->str_data = (unsigned char *)malloc((size_t)length);
    memcpy(result->str_data, data, (size_t)length);
    result->regex = regex;
    result->region = onig_region_new();
    result->has_g_anchor = has_g_anchor(data, length);
    result->last_search_str_cache_id = 0;
    result->last_search_position = 0;
    result->last_search_onig_option = ONIG_OPTION_NONE;
    result->last_search_matched = false;
    return result;
}

static void free_onig_reg_exp(OnigRegExp *re) {
    if (!re) {
        return;
    }
    free(re->str_data);
    onig_region_free(re->region, 1);
    /* regex_t released by onig_regset_free for successful scanner; on failure path onig_free each */
    free(re);
}

static OnigRegion *search_onig_reg_exp_uncached(OnigRegExp *re, unsigned char *str_data, int str_length, int position,
                                                OnigOptionType onig_option) {
    int status = onig_search(re->regex, str_data, str_data + str_length, str_data + position, str_data + str_length,
                             re->region, onig_option);
    if (status == ONIG_MISMATCH || status < 0) {
        re->last_search_matched = false;
        return nullptr;
    }
    re->last_search_matched = true;
    return re->region;
}

static OnigRegion *search_onig_reg_exp(OnigRegExp *re, int str_cache_id, unsigned char *str_data, int str_length, int position,
                                       OnigOptionType onig_option) {
    if (re->has_g_anchor) {
        return search_onig_reg_exp_uncached(re, str_data, str_length, position, onig_option);
    }
    if (re->last_search_str_cache_id == str_cache_id && re->last_search_onig_option == onig_option &&
        re->last_search_position <= position) {
        if (!re->last_search_matched) {
            return nullptr;
        }
        if (re->region->beg[0] >= position) {
            return re->region;
        }
    }
    re->last_search_str_cache_id = str_cache_id;
    re->last_search_position = position;
    re->last_search_onig_option = onig_option;
    return search_onig_reg_exp_uncached(re, str_data, str_length, position, onig_option);
}

VSCodeOnigScanner *vscode_onig_scanner_create(const unsigned char *const *patterns, const int *lengths, int count,
                                              int options, void *syntax) {
    auto **regexes = (OnigRegExp **)malloc(sizeof(OnigRegExp *) * (size_t)count);
    auto **regs = (regex_t **)malloc(sizeof(regex_t *) * (size_t)count);
    if (!regexes || !regs) {
        free(regexes);
        free(regs);
        return nullptr;
    }
    OnigSyntaxType *syn = syntax ? (OnigSyntaxType *)syntax : ONIG_SYNTAX_DEFAULT;
    for (int i = 0; i < count; i++) {
        regexes[i] = create_onig_reg_exp(patterns[i], lengths[i], options, syn);
        if (regexes[i] != nullptr) {
            regs[i] = regexes[i]->regex;
        } else {
            for (int j = 0; j < i; j++) {
                onig_free(regexes[j]->regex);
                regexes[j]->regex = nullptr;
                free_onig_reg_exp(regexes[j]);
            }
            free(regexes);
            free(regs);
            return nullptr;
        }
    }
    OnigRegSet *rset = nullptr;
    onig_regset_new(&rset, count, regs);
    free(regs);

    auto *scanner = (VSCodeOnigScanner *)malloc(sizeof(VSCodeOnigScanner));
    scanner->rset = rset;
    scanner->regexes = regexes;
    scanner->count = count;
    return scanner;
}

void vscode_onig_scanner_free(VSCodeOnigScanner *scanner) {
    if (!scanner) {
        return;
    }
    for (int i = 0; i < scanner->count; i++) {
        free_onig_reg_exp(scanner->regexes[i]);
    }
    free(scanner->regexes);
    onig_regset_free(scanner->rset);
    free(scanner);
}

int32_t *vscode_onig_scanner_find_next_match(VSCodeOnigScanner *scanner, int str_cache_id, const unsigned char *str_data,
                                             int str_length, int position_bytes, int options) {
    if (!scanner) {
        return nullptr;
    }
    auto *sdata = (unsigned char *)str_data;
    int best_location = 0;
    int best_result_index = 0;
    OnigRegion *best_result = nullptr;
    OnigOptionType opts = (OnigOptionType)options;

    if (str_length < 1000) {
        int best_result_index_rs =
            onig_regset_search(scanner->rset, sdata, sdata + str_length, sdata + position_bytes, sdata + str_length,
                               ONIG_REGSET_POSITION_LEAD, opts, &best_location);
        if (best_result_index_rs < 0) {
            return nullptr;
        }
        return encode_onig_region_heap(onig_regset_get_region(scanner->rset, best_result_index_rs), best_result_index_rs);
    }

    for (int i = 0; i < scanner->count; i++) {
        OnigRegion *result = search_onig_reg_exp(scanner->regexes[i], str_cache_id, sdata, str_length, position_bytes, opts);
        if (result != nullptr && result->num_regs > 0) {
            int location = result->beg[0];
            if (best_result == nullptr || location < best_location) {
                best_location = location;
                best_result = result;
                best_result_index = i;
            }
            if (location == position_bytes) {
                break;
            }
        }
    }
    if (best_result == nullptr) {
        return nullptr;
    }
    return encode_onig_region_heap(best_result, best_result_index);
}

void vscode_onig_free_match_result(int32_t *ptr) {
    free(ptr);
}

} /* extern "C" */
