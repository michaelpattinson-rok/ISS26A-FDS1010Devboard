#include <cassert>
#include <cstdio>
#include <cmath>
#include <algorithm>
#include "../Arduino/RevE_Arduino/avr_detector.h"
static uint16_t x[fds_avr::N];
static unsigned checks=0, accepted_cases=0, rejected_cases=0;
static double worst_error=0;
#define CHECK(v) do{++checks;if(!(v)){std::fprintf(stderr,"FAIL line%u: %s\n",__LINE__,#v);assert(v);}}while(0)
static void quiet(){for(unsigned i=0;i<fds_avr::N;i++)x[i]=338;}
// Exact ideal nominal linear cascade: CSA1ms, HP10.1ms, gain R6||C6
// (s+G*d)/(s+d), shaper499us/4.99, ADC RC1us. Not hardware evidence.
static double full_shape(double t,double charge_fc,double gain) {
    if(t<0)return 0;
    const double p[]={1000,1/.0101,1/(52300*100e-12),1/.000499,1e6};
    double response=0;
    for(unsigned i=0;i<5;i++){
        double denominator=1;
        for(unsigned j=0;j<5;j++)if(j!=i)denominator*=p[j]-p[i];
        response+=(-p[i])*(gain*p[2]-p[i])/denominator*std::exp(-p[i]*t);
    }
    return charge_fc*1e-4*4.99*p[3]*p[4]*response;
}
static double pulse(double charge,double gain,double onset,double phase=0) {
    double expected=0;
    for(unsigned i=0;i<fds_avr::N;i++) {
        double d=full_shape((double(i)-onset-phase)*.000104,charge,gain)*1024/5;
        expected=std::max(expected,d);
        x[i]=uint16_t(std::lround(338+d));
    }
    return expected;
}
static void report(const char*label,const fds_avr::Result&r,double expected) {
    std::printf("%s expected=%.6f flags=%u accepted=%u trigger=%u peak=%u local=%.6f shift=%.6f slope=%.6f local_sigma=%.6f tolerance=%.6f measured=%.6f\n",
        label,expected,r.flags,r.accepted,r.start,r.peak,r.local_baseline,r.local_shift,r.local_slope,r.local_sigma,r.baseline_tolerance,r.local_peak);
}
int main(){
    quiet();auto r=fds_avr::analyze(x,0,10,665);
    CHECK(!r.flags);CHECK(!r.accepted);CHECK(r.threshold==4);CHECK(r.baseline==338);
    CHECK(r.observation==64);CHECK(sizeof(x)+sizeof(r)+64<800);
    CHECK(fds_avr::analyze(nullptr,4,10,665).flags&fds_avr::BAD_ARGUMENT);
    CHECK(fds_avr::analyze(x,-1,10,665).flags&fds_avr::BAD_ARGUMENT);
    CHECK(fds_avr::analyze(x,4,665,10).flags&fds_avr::BAD_ARGUMENT);
    // Exact cascade sweeps: charges, phase and physical onset well within the
    // declared trigger window. Every accepted code peak must be near the known
    // sampled isolated peak, and every unresolved local baseline must reject.
    for(double gain:{27.15,53.3})for(double q:{2.2,5.5,11.,22.,40.,100.})
    for(unsigned onset:{72u,88u,104u,116u})for(double phase:{0.,.25,.5,.75}) {
        double expected=pulse(q,gain,onset,phase);
        r=fds_avr::analyze(x,4,10,665);
        if(expected>=5.5) {
            if(r.flags)report("unexpected_nominal_rejection",r,expected);
            CHECK(!r.flags);CHECK(r.accepted==1);
            const double err=std::fabs(r.local_peak-expected);
            worst_error=std::max(worst_error,err);CHECK(err<=1.5);
            CHECK(std::fabs(r.local_shift)<=r.baseline_tolerance);
            ++accepted_cases;
        } else {CHECK(r.accepted==0);++rejected_cases;}
    }
    // Reproduce old amplitude/time-dependent late-tail cases. Fixed trigger
    // qualification rejects all these physical onsets for both amplitudes.
    for(double q:{11.,22.,30.})for(unsigned onset:{150u,180u,200u}) {
        double expected=pulse(q,53.3,onset);
        r=fds_avr::analyze(x,4,10,665);report("late_fixed_window",r,expected);
        CHECK(r.flags&fds_avr::BOUNDARY);CHECK(!r.accepted);++rejected_cases;
    }
    // Same nominal positive pulse at the full intended onset range: ordinary
    // negative end tails do not veto large pulses while admitting smaller ones.
    for(double q:{11.,22.,30.,100.})for(unsigned onset:{72u,88u,104u,116u}) {
        double expected=pulse(q,53.3,onset);r=fds_avr::analyze(x,4,10,665);
        CHECK(r.accepted==1);CHECK(!r.flags);CHECK(r.negative<0);
        CHECK(std::fabs(r.local_peak-expected)<=1.5);++accepted_cases;
    }
    // Pedestal returns before the record end. Local mean must catch shifts
    // that remain below the calibrated trigger; allowable +/-1 code is removed.
    for(int drift:{-10,-3,-2,-1,1,2,3,10}) {
        double expected=pulse(22,53.3,88);
        for(unsigned i=40;i<200;i++)x[i]=uint16_t(int(x[i])+drift);
        r=fds_avr::analyze(x,4,10,665);report("pedestal_drift",r,expected);
        if(std::abs(drift)>1){CHECK(r.flags);CHECK(!r.accepted);++rejected_cases;}
        else {CHECK(r.accepted==1);CHECK(std::fabs(r.local_peak-expected)<=1.5);++accepted_cases;}
    }
    for(double slope:{-.2,-.1,.1,.2}) {
        pulse(22,53.3,88);
        for(unsigned i=40;i<180;i++)x[i]=uint16_t(std::lround(x[i]+slope*(i-40)));
        r=fds_avr::analyze(x,4,10,665);
        CHECK(r.flags);CHECK(!r.accepted);++rejected_cases;
    }
    // An earlier nominal pulse within the record cannot become a recovered
    // second amplitude. Both positive excursions, or prehistory, reject.
    for(double q1:{11.,22.,100.})for(double q2:{2.2,11.,22.})for(unsigned sep:{20u,40u,80u}) {
        pulse(q1,53.3,48);
        for(unsigned i=0;i<fds_avr::N;i++){
            const double extra=full_shape((double(i)-48-sep)*.000104,q2,53.3)*1024/5;
            x[i]=uint16_t(std::lround(x[i]+extra));
        }
        r=fds_avr::analyze(x,4,10,665);CHECK(r.flags);CHECK(!r.accepted);++rejected_cases;
    }
    // Unknown previous pulse outside this finite record: sweep tail spacing
    // and amplitude ratios. Passing local recovery must bound nominal error;
    // unresolved tails must never report an accepted amplitude.
    for(double q1:{22.,100.,300.})for(double q2:{2.2,11.,22.})
    for(double spacing_ms:{10.,15.,22.,40.,60.,80.,100.,150.}) {
        const double expected=pulse(q2,53.3,88);
        for(unsigned i=0;i<fds_avr::N;i++) {
            const double prior=full_shape((double(i)-88)*.000104+spacing_ms*.001,q1,53.3)*1024/5;
            x[i]=uint16_t(std::lround(x[i]+prior));
        }
        r=fds_avr::analyze(x,4,10,665);
        if(r.accepted) {
            const double err=std::fabs(r.local_peak-expected);
            if(err>1.5)report("unqualified_prior_tail",r,expected);
            CHECK(err<=1.5);CHECK(!r.flags);++accepted_cases;
            worst_error=std::max(worst_error,err);
        }else {CHECK(r.flags || expected<5.5);++rejected_cases;}
    }
    // Sparse exact-threshold spikes must never satisfy contiguous width.
    for(unsigned spacing:{2u,3u,8u,20u}) {
        quiet();for(unsigned i=0;i<4;i++)x[72+spacing*i]=342;
        r=fds_avr::analyze(x,4,10,665);CHECK(r.flags&fds_avr::SPIKE);CHECK(!r.accepted);++rejected_cases;
    }
    quiet();x[75]=670;r=fds_avr::analyze(x,4,10,665);CHECK(r.flags&fds_avr::CLIP);CHECK(!r.accepted);
    quiet();x[75]=0;r=fds_avr::analyze(x,4,10,665);CHECK(r.flags&fds_avr::CLIP);
    quiet();x[250]+=20;r=fds_avr::analyze(x,4,10,665);CHECK(r.flags&fds_avr::BOUNDARY);CHECK(!r.accepted);
    quiet();for(unsigned i=0;i<32;i++)x[i]=338+(i%2?20:-20);
    r=fds_avr::analyze(x,4,10,665);CHECK(r.flags&fds_avr::NOISE);CHECK(!r.accepted);
    for(unsigned i=0;i<fds_avr::N;i++)x[i]=512;
    r=fds_avr::analyze(x,4,10,665);CHECK(r.flags&fds_avr::BAD_BASELINE);
    std::printf("PASS: %u AVR native assertions; nominal accepted cases=%u rejected adversarial/subthreshold cases=%u worst sampled nominal peak error=%.6f codes; static capture/result+64=%zu bytes. No AVR target/core/timing/hardware qualification.\n",checks,accepted_cases,rejected_cases,worst_error,sizeof(x)+sizeof(r)+64);
}
