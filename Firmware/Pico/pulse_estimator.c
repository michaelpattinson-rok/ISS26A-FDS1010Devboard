#include "pulse_estimator.h"
#include <math.h>
#include <string.h>

static float median(uint16_t *a, size_t n) {
    for(size_t i=1;i<n;i++) { uint16_t x=a[i]; size_t j=i;
        while(j && a[j-1]>x) { a[j]=a[j-1];j--; } a[j]=x; }
    return n&1u ? a[n/2] : (a[n/2-1]+a[n/2])*.5f;
}
static float sample_median(const uint16_t *a,size_t n,fds_workspace *w) {
    for(size_t i=0;i<n;i++) w->work[i]=a[i]&0xfffu;
    return median(w->work,n);
}
fds_config fds_default_config(void) {
    /* 100ksps only: 100ms blind exclusion and end guard. This is a restricted
       isolated-pulse demonstration, not a fitted tail correction. Nominal
       cascade sweeps justify this setting only for the documented model. */
    return (fds_config){10000u,4u,1000u,10000u,512u,6.0f,24.0f,32.0f,0.0f,1.0f,1.0f};
}
uint32_t fds_algorithm_version(void) { return FDS_ALGORITHM_VERSION; }
void fds_analyze(const uint16_t *a,size_t n,const fds_config *c,
                 fds_workspace *w,fds_result *r) {
    fds_analyze_profile(a,n,c,w,r,FDS_POLARITY_POSITIVE);
}
void fds_analyze_profile(const uint16_t *a,size_t n,const fds_config *c,
                 fds_workspace *w,fds_result *r,fds_polarity polarity) {
    if(!r)return;
    memset(r,0,sizeof(*r));
    if((polarity!=FDS_POLARITY_NEGATIVE && polarity!=FDS_POLARITY_POSITIVE)||!a||!c||!w||n>UINT32_MAX||n<=FDS_BASELINE_SAMPLES||
       c->end_guard_samples>=n-FDS_BASELINE_SAMPLES||!c->recovery_samples||
       !c->minimum_above_threshold_samples||!c->max_positive_samples||
       c->local_baseline_samples<4||c->local_baseline_samples>FDS_BASELINE_SAMPLES||
       (c->local_baseline_samples&1u)||
       !isfinite(c->trigger_sigma)||c->trigger_sigma<3||
       !isfinite(c->minimum_threshold_codes)||c->minimum_threshold_codes<=0||
       !isfinite(c->maximum_sigma_codes)||c->maximum_sigma_codes<=0||
       !isfinite(c->fixed_threshold_codes)||c->fixed_threshold_codes<0||
       !isfinite(c->maximum_local_offset_codes)||c->maximum_local_offset_codes<0||
       !isfinite(c->maximum_local_slope_codes)||c->maximum_local_slope_codes<0) {
        r->quality_flags=FDS_BAD_ARGUMENT;return;
    }
    for(size_t i=0;i<n;i++) {
        uint16_t v=a[i]&0xfffu;
        if(a[i]&0x8000u)r->adc_errors++;
        if(v<5||v>4090)r->clipped_samples++;
    }
    if(r->adc_errors)r->quality_flags|=FDS_ADC_ERROR;
    if(r->clipped_samples)r->quality_flags|=FDS_CLIPPING;
    r->baseline=sample_median(a,FDS_BASELINE_SAMPLES,w);
    double sum=0;
    for(size_t i=0;i<FDS_BASELINE_SAMPLES;i++) {
        float d=(a[i]&0xfffu)-r->baseline;sum+=(double)d*d;
        w->work[i]=(uint16_t)lroundf(fabsf(d));
    }
    r->baseline_rms=(float)sqrt(sum/FDS_BASELINE_SAMPLES);
    r->sigma=fmaxf(1,1.4826f*median(w->work,FDS_BASELINE_SAMPLES));
    r->threshold=c->fixed_threshold_codes>0 ? c->fixed_threshold_codes :
        fmaxf(c->minimum_threshold_codes,c->trigger_sigma*r->sigma);
    if(r->threshold+.001f<c->trigger_sigma*r->sigma)r->quality_flags|=FDS_THRESHOLD_BELOW_NOISE;
    if(r->sigma>c->maximum_sigma_codes)r->quality_flags|=FDS_NOISY_BASELINE;
    if(r->baseline<256||r->baseline>3839)r->quality_flags|=FDS_BAD_BASELINE;
    uint32_t outliers=0;
    for(size_t i=0;i<FDS_BASELINE_SAMPLES;i++)
        if(fabsf((a[i]&0xfffu)-r->baseline)>=r->threshold)outliers++;
    if(outliers>FDS_BASELINE_SAMPLES/100u)r->quality_flags|=FDS_BASELINE_CONTAMINATED;
    float first=sample_median(a,FDS_BASELINE_SAMPLES/2,w);
    float second=sample_median(a+FDS_BASELINE_SAMPLES/2,FDS_BASELINE_SAMPLES/2,w);
    r->tail_baseline_shift=sample_median(a+n-FDS_BASELINE_SAMPLES,FDS_BASELINE_SAMPLES,w)-r->baseline;
    if(fabsf(second-first)>c->maximum_local_slope_codes||
       fabsf(r->tail_baseline_shift)>c->maximum_local_offset_codes)
        r->quality_flags|=FDS_BASELINE_DRIFT;
    r->analysis_start=FDS_BASELINE_SAMPLES;
    r->analysis_end=(uint32_t)n-c->end_guard_samples;
    for(uint32_t i=r->analysis_start;i<r->analysis_end;) {
        float v=(float)polarity*((a[i]&0xfffu)-r->baseline);
        if(v<r->threshold){i++;continue;}
        fds_event e={0};e.start=i;e.peak=i;e.end=i;
        const uint32_t half=c->local_baseline_samples/2;
        float older=sample_median(a+i-c->local_baseline_samples,half,w);
        float recent=sample_median(a+i-half,half,w);
        e.local_baseline_codes=sample_median(a+i-c->local_baseline_samples,c->local_baseline_samples,w);
        e.local_offset_codes=e.local_baseline_codes-r->baseline;
        e.local_slope_codes=recent-older;
        e.baseline_tolerance_codes=c->maximum_local_offset_codes;
        e.slope_tolerance_codes=c->maximum_local_slope_codes;
        for(uint32_t j=0;j<c->local_baseline_samples;j++)
            w->work[j]=(uint16_t)lroundf(fabsf((a[i-c->local_baseline_samples+j]&0xfffu)-e.local_baseline_codes));
        e.local_sigma_codes=fmaxf(1,1.4826f*median(w->work,c->local_baseline_samples));
        if(fabsf(e.local_offset_codes)>e.baseline_tolerance_codes||
           fabsf(e.local_slope_codes)>e.slope_tolerance_codes||
           e.local_sigma_codes>c->maximum_sigma_codes||
           r->threshold+.001f<c->trigger_sigma*e.local_sigma_codes)
            e.flags|=FDS_LOCAL_BASELINE;
        e.peak_delta_codes=(float)polarity*((a[i]&0xfffu)-e.local_baseline_codes);
        uint32_t remaining=(uint32_t)n-i;
        uint32_t span=c->recovery_samples<remaining?c->recovery_samples:remaining;
        uint32_t stop=i+span;
        if(i==r->analysis_start||span<c->recovery_samples)e.flags|=FDS_BOUNDARY_PULSE;
        bool fell=false;float valley=e.peak_delta_codes;
        uint32_t last_above=i,run=0;
        for(uint32_t j=i;j<stop;j++) {
            float d=(float)polarity*((a[j]&0xfffu)-e.local_baseline_codes);
            if(d>=r->threshold) {
                e.above_threshold_samples++;last_above=j;run++;
                if(run>e.contiguous_above_samples)e.contiguous_above_samples=run;
            }else run=0;
            if(d>e.peak_delta_codes){e.peak_delta_codes=d;e.peak=j;}
            if(d<e.negative_tail_codes)e.negative_tail_codes=d;
            /* A return to baseline at exactly the threshold also ends a lobe. */
            if(!fell && d<=e.peak_delta_codes-r->threshold){fell=true;valley=d;}
            if(fell) {
                if(d<valley)valley=d;
                if(d>=r->threshold && d>=valley+r->threshold){e.flags|=FDS_PILEUP;fell=false;}
            }
        }
        if(e.contiguous_above_samples<c->minimum_above_threshold_samples)e.flags|=FDS_SHORT_SPIKE;
        if(last_above-e.start>=c->max_positive_samples)e.flags|=FDS_LONG_PULSE;
        e.end=stop;r->candidates++;
        if(r->stored<FDS_MAX_EVENTS)r->events[r->stored++]=e;
        else r->quality_flags|=FDS_EVENT_OVERFLOW;
        r->quality_flags|=e.flags;
        uint32_t counted_end=stop<r->analysis_end?stop:r->analysis_end;
        r->dead_samples+=counted_end-i;i=stop;
    }
    r->observation_samples=r->analysis_end-r->analysis_start;
    /* Conservative whole-record rejection. Diagnostic candidate heights are not
       accepted amplitudes if any acquisition or processing defect is present. */
    r->valid_record=r->quality_flags==0;
    r->accepted=r->valid_record?r->candidates:0;
}
