#ifndef SIGNAL_BENCH_PROTOCOL_H
#define SIGNAL_BENCH_PROTOCOL_H
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>

static inline bool sb_token_valid(const char *s) {
    if (strlen(s) != 32) return false;
    for (size_t i = 0; i < 32; ++i)
        if (!((s[i] >= '0' && s[i] <= '9') || (s[i] >= 'a' && s[i] <= 'f'))) return false;
    return true;
}
static inline uint32_t sb_crc32(const uint16_t *words, size_t n) {
    uint32_t crc = 0xffffffffu;
    for (size_t i = 0; i < n; ++i) {
        for (unsigned j = 0; j < 2; ++j) {
            crc ^= (words[i] >> (8 * j)) & 255u;
            for (unsigned b = 0; b < 8; ++b)
                crc = (crc >> 1) ^ (0xedb88320u & (0u - (crc & 1u)));
        }
    }
    return crc ^ 0xffffffffu;
}
static inline uint32_t sb_crc32_bytes_update(uint32_t crc, const void *data, size_t n) {
    const uint8_t *bytes=data;
    for (size_t i = 0; i < n; ++i) {
        crc ^= (unsigned char)bytes[i];
        for (unsigned b = 0; b < 8; ++b)
            crc = (crc >> 1) ^ (0xedb88320u & (0u - (crc & 1u)));
    }
    return crc;
}
#endif
