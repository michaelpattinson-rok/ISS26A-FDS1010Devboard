#ifndef SIGNAL_BENCH_ADC_RATE_H
#define SIGNAL_BENCH_ADC_RATE_H

#include <stdbool.h>
#include <stdint.h>

static inline bool sb_stream_adc_divider256(uint32_t clock, uint32_t requested, uint32_t *divider) {
    if (requested < 10000u || requested > 500000u || clock < 96u * requested) return false;
    const uint64_t period256 = ((uint64_t)clock * 256u + requested / 2u) / requested;
    if (period256 > 0x10000ffu) return false;

    /* On the Pico W, a periodic 96-cycle trigger skipped conversions.
     * Choose back-to-back conversions or a periodic interval of at least
     * 97 cycles, whichever is closer when the request is in between. */
    if (period256 < 97u * 256u) {
        const bool free_running = (uint64_t)requested * (2u * 96u * 97u) >= (uint64_t)clock * (96u + 97u);
        *divider = free_running ? 0u : 96u * 256u;
    } else {
        *divider = (uint32_t)(period256 - 256u);
    }
    return true;
}

#endif
