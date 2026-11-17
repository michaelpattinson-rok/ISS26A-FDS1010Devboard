#include "../pulse_estimator.h"
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#define N 32768u
static uint16_t x[N];
static fds_workspace w;
static fds_result r;
static unsigned checks, sweep_cases, sweep_qualified, sweep_rejected;
static double worst_error, prior_worst_error;
static unsigned prior_cases, prior_qualified, prior_rejected;
#define CHECK(c) do{checks++;if(!(c)){fprintf(stderr,"FAIL line%d: %s\n",__LINE__,#c);return 1;}}while(0)
static void quiet(void){for(size_t i=0;i<N;i++)x[i]=2048;}
static void analyze(void){fds_config c=fds_default_config();fds_analyze(x,N,&c,&w,&r);}
/* Exact ideal nominal five-pole schematic cascade, including R6||C6 zero.
   This is an analytical nominal model, not an amplifier/noise/tolerance model. */
static double full(double t,double charge_fc,double gain) {
    if(t<0)return 0;
    const double p[]={1000,1/.0101,1/(52300*100e-12),1/.000499,1e6};
    double response=0;
    for(unsigned i=0;i<5;i++) {
        double denominator=1;
        for(unsigned j=0;j<5;j++)if(j!=i)denominator*=p[j]-p[i];
        response+=(-p[i])*(gain*p[2]-p[i])/denominator*exp(-p[i]*t);
    }
    return charge_fc*1e-4*4.99*p[3]*p[4]*response*4096/3.3;
}
static double make_pair(double q1,double q2,double gain,unsigned onset,unsigned separation,double phase) {
    double isolated_second=0;
    for(unsigned i=0;i<N;i++) {
        double t=((double)i-onset-phase)*1e-5;
        double second=full(t-separation*1e-5,q2,gain);
        isolated_second=fmax(isolated_second,second);
        double d=full(t,q1,gain)+second;
        x[i]=(uint16_t)lround(fmax(0,fmin(4095,2048+d)));
    }
    return isolated_second;
}
static void rectangle(unsigned start,unsigned width,unsigned height) {
    for(unsigned i=start;i<start+width;i++)x[i]=(uint16_t)(2048+height);
}
int main(void) {
    fds_config cfg=fds_default_config();
    quiet();analyze();CHECK(r.valid_record&&r.accepted==0);CHECK(r.baseline==2048);
    CHECK(r.analysis_start==2048&&r.analysis_end==N-10000);
    CHECK(r.dead_samples==0&&r.observation_samples==N-12048);CHECK(r.threshold==24);
    make_pair(50,0,27.15,6000,0,0);analyze();CHECK(r.valid_record&&r.accepted==1);
    CHECK(r.events[0].negative_tail_codes< -35);CHECK(r.dead_samples==10000);
    CHECK(r.events[0].local_baseline_codes==2048&&r.events[0].local_offset_codes==0);
    CHECK(r.events[0].baseline_tolerance_codes==1&&r.events[0].slope_tolerance_codes==1);
    CHECK(r.events[0].contiguous_above_samples>=4);
    /* Original audit counterexamples: a second diagnostic candidate must not be
       presented as a qualified height; a subthreshold pulse is explicitly blind. */
    make_pair(100,12.5,27.15,6000,2200,0);analyze();
    CHECK(r.quality_flags&FDS_PILEUP);CHECK(r.accepted==0);
    make_pair(22,2.2,53.3,6000,2200,0);analyze();CHECK(r.accepted==0);
    CHECK(r.quality_flags&FDS_PILEUP);
    make_pair(100,1,27.15,6000,2200,0);analyze();CHECK(r.candidates<=1);
    CHECK(r.dead_samples==10000); /* No second amplitude is available. */
    /* Every baseline/drift case either rejects or locally subtracts the
       demonstrably <=1code offset. Transient +10code pedestal was formerly clean. */
    for(int offset=-12;offset<=12;offset++) {
        make_pair(5,0,27.15,6000,0,0);
        for(unsigned i=4000;i<24000;i++)x[i]=(uint16_t)((int)x[i]+offset);
        analyze();CHECK(r.stored==1);
        if(abs(offset)>1){CHECK(r.quality_flags&FDS_LOCAL_BASELINE);CHECK(r.accepted==0);}
        else {CHECK(r.valid_record&&r.accepted==1);CHECK(r.events[0].local_offset_codes==offset);CHECK(fabs(r.events[0].peak_delta_codes-full(.00066,5,27.15))<1.01);}
    }
    for(unsigned mode=0;mode<3;mode++) {
        make_pair(5,0,27.15,6000,0,0);
        for(unsigned i=4000;i<24000;i++) {
            double shift=mode==0?10.0*(i-4000)/2000.0:mode==1?-10.0*(i-4000)/2000.0:10*sin((i-4000)*.0002);
            x[i]=(uint16_t)lround(x[i]+shift);
        }
        analyze();CHECK(r.accepted==0);CHECK(r.quality_flags&FDS_LOCAL_BASELINE);
    }
    /* Contiguous width, including exact-threshold and separated spike cases. */
    for(unsigned height=24;height<=100;height+=19)for(unsigned gap=1;gap<=31;gap+=3) {
        quiet();for(unsigned j=0;j<4;j++)x[6000+j*(gap+1)]=(uint16_t)(2048+height);
        analyze();CHECK(r.accepted==0);CHECK(r.quality_flags&FDS_SHORT_SPIKE);
        CHECK(r.events[0].contiguous_above_samples==1);
    }
    quiet();for(unsigned j=0;j<4;j++)x[6000+j*2]=2060;
    cfg=fds_default_config();cfg.fixed_threshold_codes=12;fds_analyze(x,N,&cfg,&w,&r);
    CHECK(r.quality_flags&FDS_SHORT_SPIKE);CHECK(r.accepted==0);CHECK(r.events[0].contiguous_above_samples==1);
    quiet();rectangle(6000,4,24);analyze();CHECK(r.valid_record&&r.accepted==1);
    CHECK(r.events[0].contiguous_above_samples==4);
    quiet();rectangle(6000,1500,300);analyze();CHECK(r.quality_flags&FDS_LONG_PULSE);
    quiet();x[6000]=4095;analyze();CHECK(r.quality_flags&FDS_CLIPPING);
    quiet();x[6000]|=0x8000u;analyze();CHECK(r.quality_flags&FDS_ADC_ERROR);
    quiet();rectangle(2040,60,400);analyze();CHECK(!r.valid_record);
    quiet();for(unsigned i=N/2;i<N;i++)x[i]+=10;analyze();CHECK(r.quality_flags&FDS_BASELINE_DRIFT);
    quiet();for(unsigned i=0;i<N;i++)x[i]=(uint16_t)(2048+(i&1?100:-100));analyze();CHECK(r.quality_flags&FDS_NOISY_BASELINE);
    quiet();cfg.fixed_threshold_codes=30;fds_analyze(x,N,&cfg,&w,&r);CHECK(r.valid_record&&r.threshold==30);
    cfg.fixed_threshold_codes=3;fds_analyze(x,N,&cfg,&w,&r);CHECK(r.quality_flags&FDS_THRESHOLD_BELOW_NOISE);
    cfg=fds_default_config();cfg.trigger_sigma=NAN;fds_analyze(x,N,&cfg,&w,&r);CHECK(r.quality_flags&FDS_BAD_ARGUMENT);
    fds_analyze(NULL,N,&cfg,&w,&r);CHECK(r.quality_flags&FDS_BAD_ARGUMENT);
    cfg=fds_default_config();cfg.local_baseline_samples=4096;fds_analyze(x,N,&cfg,&w,&r);CHECK(r.quality_flags&FDS_BAD_ARGUMENT);
    cfg=fds_default_config();cfg.end_guard_samples=N;fds_analyze(x,N,&cfg,&w,&r);CHECK(r.quality_flags&FDS_BAD_ARGUMENT);
    quiet();cfg=fds_default_config();cfg.recovery_samples=10;
    for(unsigned i=0;i<60;i++)rectangle(5000+i*200,4,100);
    fds_analyze(x,N,&cfg,&w,&r);CHECK(r.quality_flags&FDS_EVENT_OVERFLOW);
    CHECK(r.candidates==60&&r.stored==FDS_MAX_EVENTS);CHECK(r.accepted==0);
    /* Full-cascade sweeps across both gains, first/second amplitudes, phases and
       separations. Compare any qualified second height to its ISOLATED sampled
       model peak. Rejected or blind cases are counted, never treated as accurate. */
    const double gains[]={27.15,53.3}, q1s[]={5,22,100,125}, q2s[]={1,3.2,5,12.5,22,50,125};
    const unsigned spacings[]={100,350,2000,2200,4000,8000,10000,10512,11000,14000};
    const double phases[]={0,.37,.85};
    for(unsigned g=0;g<2;g++)for(unsigned a=0;a<4;a++)for(unsigned b=0;b<7;b++)
    for(unsigned s=0;s<10;s++)for(unsigned p=0;p<3;p++) {
        double expected=make_pair(q1s[a],q2s[b],gains[g],4000,spacings[s],phases[p]);
        analyze();sweep_cases++;
        if(r.valid_record&&r.accepted==2) {
            double error=fabs(r.events[1].peak_delta_codes-expected);
            worst_error=fmax(worst_error,error);sweep_qualified++;
            CHECK(r.events[1].start-r.events[0].start>=10000);CHECK(error<=1.01);
            CHECK(fabs(r.events[1].local_offset_codes)<=1);
        }else {sweep_rejected++;CHECK(r.accepted<2);}
        if(spacings[s]<=8000)CHECK(r.accepted<=1);
    }
    CHECK(sweep_qualified>100);CHECK(sweep_cases==1680);
    /* A prior pulse may precede the retained record. Its residual must not be
       hidden by a contaminated initial pedestal and then yield a clean height. */
    const double prior_times[]={.002,.005,.010,.020,.022,.040,.080,.100,.150};
    const double prior_q[]={5,100,125}, current_q[]={3.2,5,22,50};
    for(unsigned g=0;g<2;g++)for(unsigned a=0;a<3;a++)for(unsigned b=0;b<4;b++)
    for(unsigned s=0;s<9;s++)for(unsigned p=0;p<3;p++) {
        double expected=0;
        for(unsigned i=0;i<N;i++) {
            double current=full(((double)i-6000-phases[p])*1e-5,current_q[b],gains[g]);
            expected=fmax(expected,current);
            double previous=full(i*1e-5+prior_times[s],prior_q[a],gains[g]);
            x[i]=(uint16_t)lround(fmax(0,fmin(4095,2048+current+previous)));
        }
        analyze();prior_cases++;
        if(r.valid_record&&r.accepted==1) {
            double error=fabs(r.events[0].peak_delta_codes-expected);
            prior_qualified++;prior_worst_error=fmax(prior_worst_error,error);
            CHECK(error<=1.01);CHECK(fabs(r.events[0].local_offset_codes)<=1);
        }else {prior_rejected++;CHECK(r.accepted==0);}
    }
    CHECK(prior_cases==648);CHECK(prior_qualified>100);CHECK(prior_rejected>100);
    printf("PASS: Pico assertions=%u sweep_cases=%u qualified_second=%u rejected_or_blind=%u worst_qualified_error_codes=%.6f\n",checks,sweep_cases,sweep_qualified,sweep_rejected,worst_error);
    printf("prior_record_sweep_cases=%u qualified=%u rejected=%u worst_qualified_error_codes=%.6f\n",prior_cases,prior_qualified,prior_rejected,prior_worst_error);
    return 0;
}
