#include "../signal_bench_adc_rate.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>

int main(void) {
    const uint32_t clock = 48000000u;
    uint32_t divider = 0;
    const uint32_t presets[] = {25000, 50000, 100000, 125000, 200000, 250000, 400000, 500000};
    for (unsigned i = 0; i < sizeof presets / sizeof presets[0]; i++) {
        const uint32_t rate = presets[i];
        assert(sb_stream_adc_divider256(clock, rate, &divider));
        assert(divider == (rate == 500000u ? 0u : (clock / rate - 1u) * 256u));
    }
    assert(!sb_stream_adc_divider256(clock, 9999, &divider));
    assert(!sb_stream_adc_divider256(clock, 500001, &divider));
    assert(!sb_stream_adc_divider256(47000000u, 500000, &divider));
    assert(sb_stream_adc_divider256(clock, 496999, &divider) && divider == 96u * 256u);
    assert(sb_stream_adc_divider256(clock, 498001, &divider) && divider == 0u);
    for (uint32_t rate = 10000; rate <= 500000; rate++) {
        assert(sb_stream_adc_divider256(clock, rate, &divider));
        assert(divider == 0 || divider >= 96u * 256u);
        const double configured = divider == 0 ? (double)clock / 96 : (double)clock * 256 / (divider + 256u);
        assert(fabs(configured - rate) <= rate * 0.006);
    }
    puts("PASS all 490,001 requested rates and the free-running boundary.");
}
