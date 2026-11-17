#ifndef SIGNAL_BENCH_AVERAGE_H
#define SIGNAL_BENCH_AVERAGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

static inline bool sb_average_valid_factor(unsigned factor) {
    return factor>=4u && factor<=64u && !(factor&(factor-1u));
}

/* Format AVG1. Low bits contain the sum of non-error ADC codes,
 * then error, low rail, and high rail counts. Values are little-endian. */
static inline size_t sb_average_encode(uint8_t *out, const uint16_t *words, unsigned factor) {
    const unsigned log2=(unsigned)__builtin_ctz(factor);
    unsigned sum=0, errors=0, low=0, high=0;
    for(unsigned i=0;i<factor;i++) {
        const unsigned word=words[i];
        if(word&0x8000u) { errors++; continue; }
        const unsigned code=word&4095u;
        sum+=code;
        low+=code==0u;
        high+=code==4095u;
    }
    const unsigned sum_bits=12u+log2, count_bits=1u+log2;
    const uint64_t value=(uint64_t)sum | ((uint64_t)errors<<sum_bits) |
        ((uint64_t)low<<(sum_bits+count_bits)) | ((uint64_t)high<<(sum_bits+2u*count_bits));
    const size_t bytes=(sum_bits+3u*count_bits+7u)/8u;
    for(size_t i=0;i<bytes;i++)out[i]=(uint8_t)(value>>(i*8u));
    return bytes;
}
#endif
