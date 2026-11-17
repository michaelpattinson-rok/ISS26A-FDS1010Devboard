/* Shared-core polarity and raw preservation tests using the established fixture. */
#define main preserved_estimator_suite
#include "test_estimator.c"
#undef main
static uint16_t original[N];
static fds_result positive, negative;
static void mirror(void) {
    for(size_t i=0;i<N;i++) {
        unsigned code=x[i]&0xfffu;
        unsigned reflected=4096u-code;
        if(reflected>4095u)reflected=4095u;
        x[i]=(uint16_t)((x[i]&0x8000u)|reflected);
    }
}
int main(void) {
    fds_config cfg=fds_default_config();
    CHECK(fds_algorithm_version()==2);
    make_pair(5,0,27.15,6000,0,0);
    memcpy(original,x,sizeof x);
    fds_analyze_profile(x,N,&cfg,&w,&positive,FDS_POLARITY_POSITIVE);
    CHECK(positive.valid_record && positive.accepted==1);
    CHECK(!memcmp(x,original,sizeof x));
    mirror();memcpy(original,x,sizeof x);
    fds_analyze_profile(x,N,&cfg,&w,&negative,FDS_POLARITY_NEGATIVE);
    CHECK(negative.valid_record && negative.accepted==1);
    CHECK(negative.events[0].start==positive.events[0].start);
    CHECK(negative.events[0].peak==positive.events[0].peak);
    CHECK(negative.events[0].peak_delta_codes==positive.events[0].peak_delta_codes);
    CHECK(negative.events[0].negative_tail_codes==positive.events[0].negative_tail_codes);
    CHECK(!memcmp(x,original,sizeof x));
    fds_analyze(x,N,&cfg,&w,&r);CHECK(r.candidates==0);
    for(unsigned which=0;which<6;which++) {
        make_pair(5,0,27.15,6000,0,0);
        if(which==0)x[0]|=0x8000u;
        if(which==1)x[6000]=4095;
        if(which==2)for(unsigned i=N/2;i<N;i++)x[i]+=10;
        if(which==3)for(unsigned i=0;i<N;i++)x[i]=(uint16_t)(2048+(i&1?100:-100));
        if(which==4)make_pair(100,12.5,27.15,6000,2200,0);
        if(which==5)for(unsigned i=4000;i<24000;i++)x[i]+=10;
        fds_analyze(x,N,&cfg,&w,&positive);
        mirror();fds_analyze_profile(x,N,&cfg,&w,&negative,FDS_POLARITY_NEGATIVE);
        CHECK(positive.accepted==0 && negative.accepted==0);
        CHECK(positive.quality_flags==negative.quality_flags);
    }
    quiet();x[6000]=2100;mirror();
    fds_analyze_profile(x,N,&cfg,&w,&r,FDS_POLARITY_NEGATIVE);CHECK(r.quality_flags&FDS_SHORT_SPIKE);
    fds_analyze_profile(x,N,&cfg,&w,&r,(fds_polarity)0);CHECK(r.quality_flags==FDS_BAD_ARGUMENT);
    puts("PASS: polarity profiles, mirrored analytical pulse, biphasic rebound, raw preservation, conservative rejection");
    return 0;
}
