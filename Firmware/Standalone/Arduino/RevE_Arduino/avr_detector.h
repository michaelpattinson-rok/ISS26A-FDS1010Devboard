#ifndef FDS_REVE_AVR_DETECTOR_H
#define FDS_REVE_AVR_DETECTOR_H
#include <stdint.h>
#include <math.h>
namespace fds_avr {
/* Finite-record, one-pulse demonstration. The threshold crossing, not the
   unobservable physical onset, must be in this fixed window at 104 us/sample.
   This window leaves time for the nominal positive lobe; it is not exposure. */
enum { N=256, BASELINE=32, TRIGGER_START=64, TRIGGER_STOP=128,
       END_GUARD=16, HOLDOFF=N, LOCAL=32 };
enum Flags { BAD_BASELINE=1, NOISE=2, CLIP=4, PILEUP=8, SPIKE=16,
    LONG_PULSE=32, TIMING=64, BOUNDARY=128, RECOVERY=256, DRIFT=512,
    BAD_ARGUMENT=1024, TIMEOUT=2048 };
struct Result {
    float baseline,sigma,threshold,positive,negative;
    float local_baseline,local_sigma,local_shift,local_slope,baseline_tolerance;
    float local_peak;
    uint16_t flags,candidates,accepted,observation,dead,start,peak,end;
};
inline Result analyze(const uint16_t *x, float fixed_threshold, uint16_t lower, uint16_t upper) {
    Result r={};
    if(!x || !isfinite(fixed_threshold) || fixed_threshold<0 || lower>=upper) {
        r.flags=BAD_ARGUMENT;return r;
    }
    float sum=0;
    for(uint16_t i=0;i<BASELINE;i++)sum+=x[i];
    r.baseline=sum/BASELINE;
    float ss=0;
    for(uint16_t i=0;i<BASELINE;i++){float d=x[i]-r.baseline;ss+=d*d;}
    r.sigma=sqrtf(ss/BASELINE);
    if(r.baseline<250 || r.baseline>450)r.flags|=BAD_BASELINE;
    if(r.sigma>6)r.flags|=NOISE;
    const float noise_threshold=fmaxf(4,6*r.sigma);
    r.threshold=fixed_threshold>0?fixed_threshold:noise_threshold;
    if(r.threshold<noise_threshold)r.flags|=NOISE;
    /* Empirical local-baseline gate, in ADC codes; this is not a calibrated
       voltage/energy accuracy bound. Each event exposes the actual values. */
    r.baseline_tolerance=fmaxf(1,0.5f*r.sigma);
    r.observation=TRIGGER_STOP-TRIGGER_START;
    bool was_above=false;
    for(uint16_t i=0;i<N;i++) {
        const float d=x[i]-r.baseline;
        r.positive=fmaxf(r.positive,d);r.negative=fminf(r.negative,d);
        if(x[i]<=lower || x[i]>=upper)r.flags|=CLIP;
        const bool above=d>=r.threshold;
        if(above && !was_above) {
            r.candidates++;
            if(r.candidates>1)r.flags|=PILEUP;
            if(i<TRIGGER_START || i>=TRIGGER_STOP)r.flags|=BOUNDARY;
            uint16_t end=i;
            while(end<N && x[end]-r.baseline>=r.threshold)end++;
            const uint16_t width=end-i;
            if(width<2)r.flags|=SPIKE;
            if(width>80)r.flags|=LONG_PULSE;
            if(end>=N-END_GUARD)r.flags|=BOUNDARY;
            if(r.candidates==1) {
                r.start=i;r.peak=i;r.end=end;
                r.local_baseline=r.baseline;
                if(i<LOCAL)r.flags|=RECOVERY;
                else {
                    float pre=0,first=0,second=0;
                    for(uint16_t j=i-LOCAL;j<i;j++) {
                        pre+=x[j];
                        if(j<i-LOCAL/2)first+=x[j];else second+=x[j];
                    }
                    r.local_baseline=pre/LOCAL;
                    r.local_shift=r.local_baseline-r.baseline;
                    r.local_slope=(second-first)/(LOCAL/2);
                    float variance=0;
                    for(uint16_t j=i-LOCAL;j<i;j++){
                        float v=x[j]-r.local_baseline;variance+=v*v;
                        if(fabsf(x[j]-r.baseline)>=r.threshold)r.flags|=RECOVERY;
                    }
                    r.local_sigma=sqrtf(variance/LOCAL);
                    if(fabsf(r.local_shift)>r.baseline_tolerance ||
                       fabsf(r.local_slope)>r.baseline_tolerance)r.flags|=DRIFT;
                    if(r.local_sigma>fmaxf(1,2*r.sigma))r.flags|=RECOVERY;
                }
                r.local_peak=x[i]-r.local_baseline;
                for(uint16_t j=i;j<end;j++)if(x[j]-r.local_baseline>r.local_peak){
                    r.local_peak=x[j]-r.local_baseline;r.peak=j;
                }
                r.dead=i<TRIGGER_STOP ? TRIGGER_STOP-(i<TRIGGER_START?TRIGGER_START:i):0;
            }
        }
        was_above=above;
    }
    /* Negative late samples can be the ordinary bipolar tail of the sole
       complete positive lobe. They do not create an amplitude-dependent end
       veto. A new positive excursion is still a boundary/pileup defect.
       Subthreshold/mutually unresolved events remain unidentifiable. */
    if(!r.flags && r.candidates==1)r.accepted=1;
    return r;
}
}
#endif
