/* Rev E: RP2040/RP2350 Pico / Pico W / Pico 2 / Pico 2 W. Finite DMA records, not continuous counting.
   Hardware compilation and bench operation are separate verification gates. */
#include <inttypes.h>
#include <math.h>
#include <stdio.h>
#include "pico/stdlib.h"
#include "hardware/adc.h"
#include "hardware/clocks.h"
#include "hardware/dma.h"
#include "hardware/gpio.h"
#include "hardware/irq.h"
#include "hardware/regs/adc.h"
#include "pulse_estimator.h"
#if !(defined(PICO_RP2040) && PICO_RP2040) && !(defined(PICO_RP2350) && PICO_RP2350)
#error "Use a supported RP2040 or RP2350 Pico target"
#endif
#ifndef FDS_ENABLE_FIXTURE
#define FDS_ENABLE_FIXTURE 0
#endif
#define ADC_GPIO 26u
#define FIXTURE_GPIO 15u
#define N_SAMPLES 32768u
#define REQUESTED_HZ 100000u

static uint16_t samples[N_SAMPLES];
static fds_workspace workspace;
static fds_result result;
_Static_assert(sizeof(samples)+sizeof(workspace)+sizeof(result)<80u*1024u, "Application capture state exceeds conservative RP2040 RAM budget");
static int dma_channel;
static volatile bool capture_done;
static volatile uint32_t finish_fcs;
static volatile uint64_t finish_us;
static uint64_t start_us,boot_us,previous_stop_us,gap_before_us,record_id;
static uint64_t session_pulses;
static double sample_hz,session_raw_s,session_count_s;
static uint32_t last_n,last_acq_flags,calibration_id;
static float frozen_threshold;
static char last_tag='b';
static bool high_gain,have_record;
enum acq_flags {ACQ_TIMEOUT=1u,ACQ_FIFO_OVER=2u,ACQ_FIFO_UNDER=4u,ACQ_ADC_ERROR=8u,
                ACQ_INVALID_COUNT=16u,ACQ_FIXTURE_TIMER=32u};

static void fixture_idle(void) {
    gpio_init(FIXTURE_GPIO);
    gpio_set_dir(FIXTURE_GPIO,GPIO_IN);
    gpio_disable_pulls(FIXTURE_GPIO);
    gpio_set_input_enabled(FIXTURE_GPIO,false);
}
#if FDS_ENABLE_FIXTURE
static int64_t fixture_edge(alarm_id_t id,void *context) {
    (void)id;(void)context;
    gpio_put(FIXTURE_GPIO,true); /* Single positive step, while ADC DMA runs. */
    return 0;
}
#endif
static void dma_finished(void) {
    uint32_t mask=1u<<(uint)dma_channel;
    if(!(dma_hw->ints0&mask))return;
    dma_hw->ints0=mask;
    adc_run(false);
    finish_fcs=adc_hw->fcs;
    finish_us=time_us_64();
    capture_done=true;
}
/* Discard startup samples through the FIFO with a deadline. SDK adc_read()
   polls READY without a timeout, so it must not be used in this warmup path. */
static uint32_t discard_warmup(void) {
    adc_run(false);adc_fifo_drain();adc_run(true);
    const uint64_t deadline=time_us_64()+50000u;
    uint32_t flags=0,polls=0;
    for(uint32_t i=0;i<32;i++) {
        while(adc_hw->fcs&ADC_FCS_EMPTY_BITS) {
            if(time_us_64()>=deadline||++polls>=1000000u){flags=ACQ_TIMEOUT;break;}
            tight_loop_contents();
        }
        if(flags)break;
        (void)adc_hw->fifo;
    }
    adc_run(false);adc_fifo_drain();return flags;
}
static uint32_t acquire(bool test) {
    uint32_t flags=0;
    adc_run(false);adc_fifo_drain();
    /* No sample acquisition is included in USB output or CPU analysis time. */
    adc_hw->fcs|=ADC_FCS_OVER_BITS|ADC_FCS_UNDER_BITS;
    adc_hw->cs|=ADC_CS_ERR_STICKY_BITS;
    capture_done=false;finish_fcs=0;finish_us=0;
    dma_hw->ints0=1u<<(uint)dma_channel;
    dma_channel_config cfg=dma_channel_get_default_config((uint)dma_channel);
    channel_config_set_transfer_data_size(&cfg,DMA_SIZE_16);
    channel_config_set_read_increment(&cfg,false);
    channel_config_set_write_increment(&cfg,true);
    channel_config_set_dreq(&cfg,DREQ_ADC);
    dma_channel_configure((uint)dma_channel,&cfg,samples,&adc_hw->fifo,N_SAMPLES,true);
    start_us=time_us_64();
    gap_before_us=previous_stop_us?start_us-previous_stop_us:start_us-boot_us;
    adc_run(true);
#if FDS_ENABLE_FIXTURE
    alarm_id_t edge_alarm=0;
    if(test) {
        edge_alarm=add_alarm_in_us(100000,fixture_edge,NULL,false);
        if(edge_alarm<=0)flags|=ACQ_FIXTURE_TIMER;
    }
#else
    (void)test;
#endif
    uint64_t deadline=start_us+(uint64_t)(2000000.0*N_SAMPLES/sample_hz)+50000u;
    while(!capture_done&&time_us_64()<deadline)tight_loop_contents();
    if(!capture_done) {
        flags|=ACQ_TIMEOUT;adc_run(false);
        dma_channel_set_irq0_enabled((uint)dma_channel,false);
        dma_channel_abort((uint)dma_channel);
        dma_hw->ints0=1u<<(uint)dma_channel;
        finish_fcs=adc_hw->fcs;finish_us=time_us_64();
        dma_channel_set_irq0_enabled((uint)dma_channel,true);
    }
#if FDS_ENABLE_FIXTURE
    if(edge_alarm>0)cancel_alarm(edge_alarm);
#endif
    previous_stop_us=finish_us;
    uint32_t remaining=dma_hw->ch[dma_channel].transfer_count;
    if(remaining>N_SAMPLES) {last_n=0;flags|=ACQ_INVALID_COUNT;}
    else last_n=N_SAMPLES-remaining;
    if(finish_fcs&ADC_FCS_OVER_BITS)flags|=ACQ_FIFO_OVER;
    if(finish_fcs&ADC_FCS_UNDER_BITS)flags|=ACQ_FIFO_UNDER;
    if(adc_hw->cs&ADC_CS_ERR_STICKY_BITS)flags|=ACQ_ADC_ERROR;
    adc_fifo_drain();
    session_raw_s+=last_n/sample_hz;
    return flags;
}
static const char *tag_name(char c) {
    return c=='c'?"quiet_calibration":c=='t'?"fixture_only":c=='s'?"source":"background";
}
static void take_record(char tag) {
    bool test=tag=='t',cal=tag=='c';
    if(!test&&!cal&&frozen_threshold<=0) {
        puts("First capture c with the dark detector in quiet background; no frozen threshold.");return;
    }
    if(test) {
#if FDS_ENABLE_FIXTURE
        puts("TEST: detector must be disconnected; passive charge fixture only on GP15/J1.");
        gpio_init(FIXTURE_GPIO);gpio_put(FIXTURE_GPIO,false);gpio_set_dir(FIXTURE_GPIO,GPIO_OUT);
#else
        puts("Fixture GPIO drive disabled at build time. No capture started.");return;
#endif
    }else fixture_idle();
    /* At least100 reference RC constants; no startup samples enter analysis. */
    sleep_ms(1000);
    last_acq_flags=discard_warmup();
    if(last_acq_flags) {
        last_n=0;start_us=finish_us=time_us_64();
        gap_before_us=previous_stop_us?start_us-previous_stop_us:start_us-boot_us;
        previous_stop_us=finish_us;
    }else last_acq_flags=acquire(test);
    fixture_idle();
    have_record=last_n>0;last_tag=tag;record_id++;
    fds_config cfg=fds_default_config();
    if(!test&&!cal)cfg.fixed_threshold_codes=frozen_threshold;
    fds_analyze(samples,last_n,&cfg,&workspace,&result);
    if(cal) {
        bool quiet_full_record=true;
        for(uint32_t i=0;i<last_n;i++)
            if(fabsf((samples[i]&0xfffu)-result.baseline)>=result.threshold)quiet_full_record=false;
        if(!last_acq_flags&&result.valid_record&&result.candidates==0&&quiet_full_record) {
            frozen_threshold=result.threshold;calibration_id++;
        }else puts("Calibration rejected. Existing threshold retained.");
    }
    bool usable=!test&&!cal&&!last_acq_flags&&result.valid_record;
    double observe=usable?result.observation_samples/sample_hz:0;
    double dead=usable?result.dead_samples/sample_hz:0;
    double count_live=observe-dead;
    uint32_t accepted=usable?result.accepted:0;
    session_pulses+=accepted;session_count_s+=count_live;
    double wall_s=(time_us_64()-boot_us)/1e6;
    printf("record=%" PRIu64 ",tag=%s,expected_gain=%s,gain_C=%.2f,n=%" PRIu32
           ",sample_hz=%.6f,nominal_raw_live_s=%.9f,observation_s=%.9f,algorithm_dead_s=%.9f,"
           "count_live_s=%.9f,gap_before_us=%" PRIu64 ",wall_window_us=%" PRIu64
           ",acq_flags=0x%02" PRIx32 ",quality_flags=0x%04" PRIx32
           ",baseline=%.3f,sigma=%.3f,baseline_rms=%.3f,threshold=%.3f,"
           "candidates=%" PRIu32 ",qualified_isolated_pulses=%" PRIu32 ",usable=%u,rate_exposure_valid=0,calibration_id=%" PRIu32
           ",session_accepted=%" PRIu64 ",session_count_live_s=%.9f,session_nominal_raw_s=%.9f,"
           "session_wall_s=%.6f,approx_blind_s=%.6f,fifo_drop_count=%s\n",
           record_id,tag_name(tag),high_gain?"HIGH_SHUNT":"LOW_OPEN",high_gain?53.3:27.15,
           last_n,sample_hz,last_n/sample_hz,observe,dead,count_live,gap_before_us,finish_us-start_us,
           last_acq_flags,result.quality_flags,result.baseline,result.sigma,result.baseline_rms,
           result.threshold,result.candidates,accepted,(unsigned)usable,calibration_id,
           session_pulses,session_count_s,session_raw_s,wall_s,fmax(0,wall_s-session_raw_s),
           last_acq_flags&ACQ_FIFO_OVER?"unknown_record_rejected":"no_overflow_flag");
    for(uint32_t i=0;i<result.stored;i++) {
        const fds_event *e=&result.events[i];
        printf("event,record=%" PRIu64 ",index=%" PRIu32 ",start=%" PRIu32
               ",peak=%" PRIu32 ",end=%" PRIu32 ",candidate_delta_codes=%.3f,candidate_delta_mV_nominal=%.3f,"
               "negative_tail_codes=%.3f,local_baseline_codes=%.3f,local_offset_codes=%.3f,"
               "local_slope_codes=%.3f,baseline_tolerance_codes=%.3f,slope_tolerance_codes=%.3f,"
               "local_sigma_codes=%.3f,contiguous_above_samples=%" PRIu32 ",height_qualified=%u,flags=0x%04" PRIx32 "\n",record_id,i,e->start,e->peak,e->end,
               e->peak_delta_codes,e->peak_delta_codes*(3300.0/4096),e->negative_tail_codes,
               e->local_baseline_codes,e->local_offset_codes,e->local_slope_codes,
               e->baseline_tolerance_codes,e->slope_tolerance_codes,e->local_sigma_codes,
               e->contiguous_above_samples,(unsigned)(usable&&!e->flags),e->flags);
    }
}
static void dump_record(void) {
    if(!have_record){puts("No record.");return;}
    printf("# RAW_BEGIN,record=%" PRIu64 ",tag=%s,sample_hz=%.6f\n",record_id,tag_name(last_tag),sample_hz);
    puts("index,time_us_nominal,raw12,adc_error,signed_delta_codes");
    for(uint32_t i=0;i<last_n;i++)printf("%" PRIu32 ",%.3f,%u,%u,%.3f\n",i,i*1e6/sample_hz,
        (unsigned)(samples[i]&0xfffu),(unsigned)((samples[i]>>15)&1u),(samples[i]&0xfffu)-result.baseline);
    puts("# RAW_END");
}
static void help(void) {
    puts("c=quiet calibration; b=background; s=source tag; d=last raw CSV; l/h=expected physical gain (clears calibration); ?=help");
    puts("t=fixture test only in an explicitly enabled fixture build; detector must be removed.");
    puts("Gain label does not move jumper. Power OFF to rewire or change gain. J2=GND/3V3/ADC, not 5V.");
    puts("Finite records: settling/analysis/USB/user waits are blind. Quality-rejected records have zero counting exposure.");
    puts("100ms exclusion/end guard, local baseline within1code and local half-window shift within1code; 24code/6sigma threshold floor.");
    puts("Candidate heights are diagnostic unless height_qualified=1; qualification is empirical isolated-model evidence only.");
    puts("Unresolved close overlap, upstream saturation and disturbances coincident with a pulse can escape these guards.");
    puts("No calibrated radiation/dose, V5 accuracy, unbiased rate or pileup/deadtime correction is claimed.");
}
int main(void) {
    stdio_init_all();boot_us=time_us_64();fixture_idle();
    adc_init();adc_gpio_init(ADC_GPIO);
    gpio_disable_pulls(ADC_GPIO);gpio_set_input_enabled(ADC_GPIO,false);
    adc_select_input(0);adc_set_round_robin(0);adc_set_temp_sensor_enabled(false);
    adc_fifo_setup(true,true,1,true,false);
    uint32_t adc_hz=clock_get_hz(clk_adc);
    uint32_t div256=(uint32_t)lround(((double)adc_hz/REQUESTED_HZ-1)*256);
    adc_set_clkdiv(div256/256.0f);
    sample_hz=adc_hz*256.0/(div256+256.0);
    dma_channel=dma_claim_unused_channel(true);
    dma_channel_set_irq0_enabled((uint)dma_channel,true);
    irq_set_exclusive_handler(DMA_IRQ_0,dma_finished);irq_set_enabled(DMA_IRQ_0,true);
    sleep_ms(1500);
    puts("FDS1010 Rev E Budget / Pico family RP2040 or RP2350 / GP26 ADC0 / 100ksps requested.");help();
    while(true) {
        int c=getchar_timeout_us(100000);
        if(c=='b'||c=='s'||c=='c'||c=='t')take_record((char)c);
        else if(c=='d')dump_record();
        else if(c=='l'||c=='h') {
            high_gain=c=='h';frozen_threshold=0;
            puts("Expected physical gain label changed; calibration cleared. Jumper changes require power OFF.");
        }else if(c=='?')help();
    }
}
