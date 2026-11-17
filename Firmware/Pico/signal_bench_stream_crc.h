#ifndef SIGNAL_BENCH_STREAM_CRC_H
#define SIGNAL_BENCH_STREAM_CRC_H

#include "signal_bench_protocol.h"

static inline void sb_stream_crc_init(uint32_t table[256]) {
    const uint8_t zero = 0;
    for (uint32_t i = 0; i < 256; ++i)
        table[i] = sb_crc32_bytes_update(i, &zero, 1);
}

static inline uint32_t sb_stream_crc_update(const uint32_t table[256],
                                            uint32_t crc, const void *data, size_t count) {
    const uint8_t *bytes = data;
    for (size_t i = 0; i < count; ++i)
        crc = (crc >> 8) ^ table[(crc ^ bytes[i]) & 0xffu];
    return crc;
}

#endif
