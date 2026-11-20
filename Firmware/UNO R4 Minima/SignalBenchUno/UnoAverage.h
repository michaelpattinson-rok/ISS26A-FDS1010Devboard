#ifndef SIGNAL_BENCH_UNO_AVERAGE_H
#define SIGNAL_BENCH_UNO_AVERAGE_H
#include <stdint.h>

namespace uno_sampling {
constexpr uint32_t clockHz = 48000000;
constexpr uint32_t minimumHz = 10000;
constexpr uint32_t maximumHz = 250000;

inline uint32_t period(uint32_t rate) {
    return rate < minimumHz || rate > maximumHz ? 0 : (clockHz + rate / 2) / rate;
}

inline bool validFactor(unsigned factor) {
    return factor == 4 || factor == 8 || factor == 16 || factor == 32 || factor == 64;
}

// AVG14 stores the exact integer sum and independent quality counts.
// All caller-supplied groups contain a whole number of conversions.
inline unsigned encodeGroup(uint8_t *destination, const uint16_t *words, unsigned factor) {
    unsigned shift = 0;
    for (unsigned n = factor; n > 1; n >>= 1) ++shift;
    const unsigned sumBits = 14 + shift, counter = 1 + shift;
    uint32_t sum = 0, errors = 0, low = 0, high = 0;
    for (unsigned i = 0; i < factor; ++i) {
        const uint16_t word = words[i];
        if (word & 0xc000u) { ++errors; continue; }
        sum += word;
        low += word == 0;
        high += word == 16383;
    }
    uint64_t group = uint64_t(sum) | (uint64_t(errors) << sumBits) |
        (uint64_t(low) << (sumBits + counter)) | (uint64_t(high) << (sumBits + 2 * counter));
    const unsigned bytes = (sumBits + 3 * counter + 7) / 8;
    for (unsigned i = 0; i < bytes; ++i) { destination[i] = uint8_t(group); group >>= 8; }
    return bytes;
}
}
#endif
