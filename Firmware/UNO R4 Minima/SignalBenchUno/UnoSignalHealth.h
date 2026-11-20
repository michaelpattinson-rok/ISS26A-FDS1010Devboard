#pragma once

#include <stdint.h>

namespace uno_health {
constexpr unsigned payloadBytes = 24;

struct Summary {
    uint32_t sum = 0;
    uint64_t squares = 0;
    uint16_t minimum = 0;
    uint16_t maximum = 0;
    uint16_t low = 0;
    uint16_t high = 0;
    uint16_t errors = 0;
};

inline uint32_t stride(uint32_t clock, uint32_t period, uint16_t block) {
    const uint32_t ticks = period * block;
    return (clock + ticks / 2) / ticks;
}

inline Summary summarize(const uint16_t *words, unsigned count) {
    Summary result;
    for (unsigned index = 0; index < count; ++index) {
        const uint16_t word = words[index];
        const uint16_t code = word & 0x3fff;
        if (word & 0x8000) { ++result.errors; continue; }
        if (code == 0) { ++result.low; continue; }
        if (code == 0x3fff) { ++result.high; continue; }
        if (!result.minimum || code < result.minimum) result.minimum = code;
        if (code > result.maximum) result.maximum = code;
        result.sum += code;
        result.squares += uint32_t(code) * code;
    }
    return result;
}
}
