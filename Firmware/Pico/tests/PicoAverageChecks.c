#include "signal_bench_average.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    for (unsigned factor=1; factor<=128; factor++) {
        assert(sb_average_valid_factor(factor)==
            (factor==4 || factor==8 || factor==16 || factor==32 || factor==64));
    }
    const size_t lengths[]={3,4,4,5,5};
    size_t i=0;
    for (unsigned factor=4;factor<=64;factor*=2,i++) {
        uint16_t words[64];
        uint8_t payload[6];
        for (unsigned sample=0;sample<factor;sample++) words[sample]=2048;
        words[0]=0;words[1]=4095;words[2]=0x8001;words[3]=2049;
        size_t length=sb_average_encode(payload,words,factor);
        assert(length==lengths[i]);
        uint64_t encoded=0;
        for (size_t byte=0;byte<length;byte++) encoded|=(uint64_t)payload[byte]<<(8*byte);
        const unsigned shift=(unsigned)__builtin_ctz(factor);
        const unsigned sum_bits=12+shift,count_bits=1+shift;
        const uint64_t mask=(1ull<<count_bits)-1;
        assert((encoded&((1ull<<sum_bits)-1))==4095u+2049u+(factor-4u)*2048u);
        for (unsigned j=0;j<3;j++)assert(((encoded>>(sum_bits+j*count_bits))&mask)==1u);
        for (unsigned sample=0;sample<factor;sample++)words[sample]=0xffff;
        (void)sb_average_encode(payload,words,factor);
        encoded=0;
        for (size_t byte=0;byte<length;byte++)encoded|=(uint64_t)payload[byte]<<(8*byte);
        assert(encoded==((uint64_t)factor<<sum_bits));
    }
    puts("PASS Pico AVG1 encoding, exact sums and independent ADC quality counts for all five factors.");
}
