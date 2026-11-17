/* Rev E: RP2040/RP2350 Pico / Pico W / Pico 2 / Pico 2 W. Finite DMA records, not continuous counting.
   Hardware compilation and bench operation are separate verification gates. */
#include <inttypes.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include "pico/stdlib.h"
#include "pico/rand.h"
#include "hardware/adc.h"
#include "hardware/clocks.h"
#include "hardware/dma.h"
#include "hardware/gpio.h"
#include "hardware/irq.h"
#include "hardware/sync.h"
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
static uint64_t start_us,boot_us,previous_stop_us,gap_before_us;
static uint64_t boot_identity;
static double sample_hz;
static float sample_clkdiv;
static uint32_t last_n,last_acq_flags,calibration_id;
static float frozen_threshold;
static bool high_gain;
enum acq_flags {ACQ_TIMEOUT=1u,ACQ_FIFO_OVER=2u,ACQ_FIFO_UNDER=4u,ACQ_ADC_ERROR=8u,
                ACQ_INVALID_COUNT=16u,ACQ_FIXTURE_TIMER=32u};

static bool stopped_fifo_drain(void);
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
    if(!stopped_fifo_drain())return ACQ_TIMEOUT;
    adc_run(true);
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
    if(!stopped_fifo_drain())flags|=ACQ_TIMEOUT;
    return flags;
}
static uint32_t acquire(bool test) {
    uint32_t flags=0;
    if(!stopped_fifo_drain()) {
        last_n=0;start_us=finish_us=time_us_64();
        gap_before_us=previous_stop_us?start_us-previous_stop_us:start_us-boot_us;
        previous_stop_us=finish_us;return ACQ_TIMEOUT;
    }
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
    if(!stopped_fifo_drain())flags|=ACQ_TIMEOUT;
    return flags;
}
#include "signal_bench_protocol.h"
#include <string.h>

/* A pending record is volatile. Only a matching ACK releases its buffer. */
static bool pending;
static bool gain_confirmed;
static char pending_token[33], pending_tag[11], last_ack_token[33];
static uint32_t pending_crc, last_ack_crc;
static bool pending_usable;
static fds_polarity processing_polarity=FDS_POLARITY_POSITIVE;
static uint32_t calibration_remaining, calibration_windows;
static float calibration_max_threshold;
static bool cal_window_accepted;
static uint32_t pending_channel;
static bool pending_calibrated;
static bool pending_observation;
static bool pending_gain_confirmed;
static uint32_t pending_calibration_id;
static void clear_calibration(void) {
    frozen_threshold=0;
    calibration_remaining=calibration_windows=0;
    calibration_max_threshold=0;
}
/* GP27/28 are permanently reserved analog inputs for the optional J3 harness.
   GP15 is the disabled fixture, GP26 is ADC0, and GP23/24/25/29 are internal. */
#define MANUAL_PINS ((0x7fffu) | (0x7fu << 16))
#define MANUAL_LEASE_US 5000000u
/* The alarm and command loop run on the same core. Command-loop mutations of
   lease state and GPIO directions are protected from the alarm interrupt. */
static volatile bool manual_active;
static volatile alarm_id_t manual_alarm_id;
static volatile uint64_t manual_deadline;
static volatile uint32_t manual_directions, manual_outputs;
static bool diagnostic_active;
static uint64_t diagnostic_deadline;
static bool adc_restore_ok=true;

static void stage_inputs(void) {
    for (uint pin=27; pin<=28; pin++) {
        gpio_set_dir(pin,GPIO_IN);
        adc_gpio_init(pin); /* NULL function, no pulls, digital receiver off. */
    }
}
/* adc_fifo_drain() in the SDK waits READY indefinitely. Both live modes use a
   deadline and a finite drain count even for a stalled or faulty ADC. */
static bool stopped_fifo_drain(void) {
    adc_run(false);
    uint64_t deadline=time_us_64()+50000u;
    uint32_t polls=0;
    while (!(adc_hw->cs&ADC_CS_READY_BITS)) {
        if (time_us_64()>=deadline || ++polls>=1000000u) return false;
        tight_loop_contents();
    }
    for (uint i=0; i<16; i++) {
        if (adc_hw->fcs&ADC_FCS_EMPTY_BITS) return true;
        (void)adc_fifo_get();
    }
    return (adc_hw->fcs&ADC_FCS_EMPTY_BITS)!=0;
}
static bool restore_capture_adc(void) {
    dma_channel_set_irq0_enabled((uint)dma_channel,false);
    dma_channel_abort((uint)dma_channel);
    dma_hw->ints0=1u<<(uint)dma_channel;
    bool drained=stopped_fifo_drain();
    adc_select_input(0); adc_set_round_robin(0);
    adc_set_temp_sensor_enabled(false); adc_set_clkdiv(sample_clkdiv);
    adc_fifo_setup(true,true,1,true,false);
    adc_hw->fcs|=ADC_FCS_OVER_BITS|ADC_FCS_UNDER_BITS;
    adc_hw->cs|=ADC_CS_ERR_STICKY_BITS;
    dma_channel_set_irq0_enabled((uint)dma_channel,true);
    stage_inputs();
    adc_restore_ok=drained;
    return drained;
}
static bool diagnostic_release(void) {
    if (!diagnostic_active && adc_restore_ok) return true;
    diagnostic_active=false;
    clear_calibration();
    return restore_capture_adc();
}
static void diagnostic_expire(void) {
    if (diagnostic_active && time_us_64()>=diagnostic_deadline)
        (void)diagnostic_release();
}
/* The three values are sequential sparse observations. Discard 32 conversions
   after each mux change before retaining one, using the nominal 100ksps divider.
   This gives a settling interval, not evidence of physical settling accuracy. */
static bool diagnostic_adc(uint channel,uint16_t *value,uint64_t *timestamp) {
    bool valid=stopped_fifo_drain();
    adc_select_input(channel); adc_set_round_robin(0);
    adc_set_temp_sensor_enabled(false); adc_set_clkdiv(sample_clkdiv);
    adc_fifo_setup(true,false,1,true,false); /* No DMA request during diagnostics. */
    adc_hw->fcs|=ADC_FCS_OVER_BITS|ADC_FCS_UNDER_BITS;
    adc_hw->cs|=ADC_CS_ERR_STICKY_BITS;
    uint16_t retained=0;
    if (valid) {
        adc_run(true);
        uint64_t deadline=time_us_64()+50000u;
        uint32_t polls=0;
        for (uint i=0; i<33 && valid; i++) {
            while (adc_hw->fcs&ADC_FCS_EMPTY_BITS) {
                if (time_us_64()>=deadline || ++polls>=1000000u) {valid=false;break;}
                tight_loop_contents();
            }
            if (!valid) break;
            retained=adc_fifo_get();
            if ((retained&0x8000u) || (adc_hw->cs&ADC_CS_ERR_STICKY_BITS) ||
                (adc_hw->fcs&(ADC_FCS_OVER_BITS|ADC_FCS_UNDER_BITS))) valid=false;
        }
    }
    *timestamp=time_us_64(); /* Read completion/attempt time, not ADC aperture. */
    if (!stopped_fifo_drain()) valid=false;
    if (valid) *value=retained&0xfffu;
    return valid;
}
static void diagnostic_read(uint32_t sequence) {
    uint16_t values[3]={0}; uint64_t timestamps[3]={0}; bool valid[3];
    for (uint channel=0; channel<3; channel++)
        valid[channel]=diagnostic_adc(channel,&values[channel],&timestamps[channel]);
    if (!restore_capture_adc()) { puts("SB1 ERROR ADC_RESTORE"); return; }
    diagnostic_deadline=time_us_64()+MANUAL_LEASE_US;
    char message[384];
    int used=snprintf(message,sizeof message,"SB1 STAGES seq=%" PRIu32,sequence);
    for (uint channel=0; channel<3; channel++) {
        char code[6]; /* Enough for any uint16_t even before the ADC mask proof. */
        if (valid[channel]) snprintf(code,sizeof code,"%u",(unsigned)values[channel]);
        else strcpy(code,"-");
        if (used<0 || (size_t)used>=sizeof message) break;
        int n=snprintf(message+used,sizeof message-(size_t)used,
            " adc%u=%s err%u=%u t%u_us=%" PRIu64,channel,code,channel,(unsigned)!valid[channel],channel,timestamps[channel]);
        if (n<0 || (size_t)n>=sizeof message-(size_t)used) {used=-1;break;}
        used+=n;
    }
    if (used<0 || (size_t)used>=sizeof message) { puts("SB1 ERROR DIAG_OVERFLOW"); return; }
    puts(message);
}
static bool diagnostic_sequence(const char *text,uint32_t *sequence) {
    size_t len=strlen(text);
    if (!len || len>10 || text[0]=='0') return false;
    uint32_t value=0;
    for (size_t i=0; i<len; i++) {
        if (text[i]<'0' || text[i]>'9') return false;
        uint32_t digit=(uint32_t)(text[i]-'0');
        if (value>(UINT32_MAX-digit)/10u) return false;
        value=value*10u+digit;
    }
    *sequence=value; return true;
}

static void manual_release_pins(void) {
    if (!manual_active) return;
    for (uint pin=0; pin<29; pin++) if (MANUAL_PINS & (1u<<pin)) {
        gpio_set_dir(pin,GPIO_IN);
        gpio_disable_pulls(pin);
    }
    manual_directions=manual_outputs=0;
    manual_active=false;
}

static int64_t manual_lease_alarm(alarm_id_t id, void *context) {
    (void)context;
    if (id != manual_alarm_id || !manual_active) return 0;
    const uint64_t now = time_us_64();
    if (now < manual_deadline) return (int64_t)(manual_deadline - now);
    manual_alarm_id = 0;
    manual_release_pins();
    return 0;
}

static bool manual_start(void) {
    const uint32_t irq_state = save_and_disable_interrupts();
    manual_deadline = time_us_64() + MANUAL_LEASE_US;
    const alarm_id_t id = add_alarm_in_us(MANUAL_LEASE_US, manual_lease_alarm, NULL, false);
    if (id > 0) {
        manual_alarm_id = id;
        manual_active = true;
    }
    restore_interrupts(irq_state);
    return id > 0;
}

static void manual_release(void) {
    const uint32_t irq_state = save_and_disable_interrupts();
    const alarm_id_t id = manual_alarm_id;
    manual_alarm_id = 0;
    manual_release_pins();
    restore_interrupts(irq_state);
    if (id > 0) (void)cancel_alarm(id);
}

static bool manual_adc(uint16_t *value) {
    if (!stopped_fifo_drain()) return false;
    adc_hw->fcs|=ADC_FCS_OVER_BITS|ADC_FCS_UNDER_BITS;
    adc_hw->cs|=ADC_CS_ERR_STICKY_BITS;
    adc_run(true);
    uint64_t deadline=time_us_64()+50000u;
    uint32_t polls=0;
    while (adc_hw->fcs&ADC_FCS_EMPTY_BITS) {
        if (time_us_64()>=deadline || ++polls>=1000000u) {
            adc_run(false);
            return false;
        }
        tight_loop_contents();
    }
    uint16_t sample=(uint16_t)adc_hw->fifo;
    adc_run(false);
    bool valid=!(sample&0x8000u) && !(adc_hw->cs&ADC_CS_ERR_STICKY_BITS) &&
               !(adc_hw->fcs&(ADC_FCS_OVER_BITS|ADC_FCS_UNDER_BITS));
    if (!stopped_fifo_drain()) valid=false;
    if (valid) *value=sample&0xfffu;
    return valid;
}

enum manual_pin_action { MANUAL_NO_CHANGE, MANUAL_INPUT, MANUAL_LOW, MANUAL_HIGH };

static void manual_live(uint pin, enum manual_pin_action action) {
    uint16_t value=0;
    if (!manual_adc(&value)) {
        manual_release();
        adc_restore_ok=false;
        puts("SB1 ERROR MANUAL_ADC_RELEASED");
        return;
    }

    const uint32_t irq_state = save_and_disable_interrupts();
    const uint64_t timestamp = time_us_64();
    if (!manual_active || timestamp >= manual_deadline) {
        restore_interrupts(irq_state);
        manual_release();
        puts("SB1 ERROR MANUAL_INACTIVE");
        return;
    }

    /* Sample before driving so an ADC fault cannot briefly enable a new
       output. Pin direction, latch and lease update together against expiry. */
    manual_deadline = timestamp + MANUAL_LEASE_US;
    const uint32_t bit = 1u << pin;
    if (action == MANUAL_INPUT) {
        gpio_set_dir(pin, GPIO_IN);
        gpio_disable_pulls(pin);
        manual_directions &= ~bit;
        manual_outputs &= ~bit;
    } else if (action != MANUAL_NO_CHANGE) {
        const bool high = action == MANUAL_HIGH;
        gpio_put(pin, high);
        gpio_set_dir(pin, GPIO_OUT);
        manual_directions |= bit;
        if (high) manual_outputs |= bit;
        else manual_outputs &= ~bit;
    }
    const uint32_t directions = manual_directions;
    const uint32_t levels = gpio_get_all() & MANUAL_PINS;
    const uint32_t outputs = manual_outputs;
    restore_interrupts(irq_state);

    /* The alarm remains enabled through all USB output, including stalls. */
    printf("SB1 LIVE time_us=%" PRIu64 " adc=%u adc_error=0 dirs=%08" PRIx32
           " levels=%08" PRIx32 " outputs=%08" PRIx32 "\n",
           timestamp, (unsigned)value, directions, levels, outputs);
}
static char metadata_line[1024];
/* One complete data frame avoids tens of thousands of small stdio writes.
   Integrity remains protected by the host's sample and metadata CRC checks. */
static char data_line[600];
static bool emit_metadata(int n, uint32_t *crc) {
    if (n < 0 || (size_t)n >= sizeof metadata_line) { puts("SB1 ERROR METADATA_OVERFLOW"); return false; }
    *crc=sb_crc32_bytes_update(*crc,metadata_line,(size_t)n);
    fputs(metadata_line,stdout);
    return true;
}
static void status(void) {
    printf("SB1 STATUS pending=%s gain=%s calibrated=%u calibration_id=%" PRIu32 " gain_confirmed=%u profile=%s\n",
           pending ? pending_token : "-", high_gain ? "HIGH" : "LOW",
           (unsigned)(frozen_threshold > 0), calibration_id,(unsigned)gain_confirmed,processing_polarity==FDS_POLARITY_NEGATIVE?"NEGATIVE":"POSITIVE");
}
#ifdef FDS_STREAMING
#include "signal_bench_stream.inc"
#define SB_BUILD_FEATURES " stream=1 stream_metrics=1 rates=25000,50000,100000,125000,200000,250000,400000,500000 diag_channels=0,1,2 pack12=1 custom_rates=10000-500000 avg_stream=1 stream_timing=1"
#define SB_BUILD_VERSION "1.10"
#else
#define SB_BUILD_FEATURES ""
#define SB_BUILD_VERSION "1.5"
#endif
static void hello(void) {
    if(!boot_identity) { boot_identity=get_rand_64();if(!boot_identity)boot_identity=1; }
    printf("SB1 HELLO version=1 firmware=" SB_BUILD_VERSION " target=pico_w boot_id=%016" PRIx64 " fixture=0 manual=1 stage_diag=1 burst=1 binary=1 profile=1 cal_series=1 observe=1" SB_BUILD_FEATURES "\n",boot_identity);
    status();
}
static void capture_channel(const char *tag, const char *token, uint32_t channel, bool observation) {
    bool cal = strcmp(tag, "CAL") == 0;
    if (pending) {
        if (!strcmp(token, pending_token) && !strcmp(tag, pending_tag) && channel==pending_channel && observation==pending_observation)
            printf("SB1 READY %s\n", token);
        else puts("SB1 ERROR PENDING");
        return;
    }
    if (!strcmp(token,last_ack_token)) { puts("SB1 ERROR ALREADY_ACKED"); return; }
    if (!gain_confirmed && !observation) { puts("SB1 ERROR GAIN_REQUIRED"); return; }
    if (!cal && !observation && strcmp(tag,"STAGE") && frozen_threshold <= 0) { puts("SB1 ERROR CALIBRATION_REQUIRED"); return; }
    if (cal) {
        frozen_threshold=0; /* A new attempt cannot reuse an older threshold. */
        if(!calibration_remaining) { calibration_windows=1; calibration_remaining=1; calibration_max_threshold=0; }
    }
    if(observation) clear_calibration();
    pending_observation=observation;
    pending_gain_confirmed=gain_confirmed;
    pending_channel=channel;
    cal_window_accepted=false;
    fixture_idle();
    sleep_ms(1000);
    adc_select_input(channel);
    last_acq_flags=discard_warmup();
    if(last_acq_flags) {
        last_n=0; start_us=finish_us=time_us_64();
        gap_before_us=previous_stop_us?start_us-previous_stop_us:start_us-boot_us;
        previous_stop_us=finish_us;
    } else last_acq_flags=acquire(false);
    fds_config cfg=fds_default_config();
    if(!cal && !observation) cfg.fixed_threshold_codes=frozen_threshold;
    fds_analyze_profile(samples,last_n,&cfg,&workspace,&result,processing_polarity);
    if(cal) {
        bool quiet=true;
        for(uint32_t i=0;i<last_n;i++)
            if(fabsf((samples[i]&0xfffu)-result.baseline)>=result.threshold)quiet=false;
        if(!last_acq_flags && result.valid_record && result.candidates==0 && quiet) {
            cal_window_accepted=true;
            calibration_max_threshold=fmaxf(calibration_max_threshold,result.threshold);
            calibration_remaining--;
            if(!calibration_remaining) {
                frozen_threshold=calibration_max_threshold;
                result.threshold=frozen_threshold;
                calibration_id++;
            }
        } else {
            clear_calibration();
        }
    }
    pending_calibrated=!observation && frozen_threshold>0;
    pending_calibration_id=observation?0:calibration_id;
    pending_usable=!cal && pending_calibrated && !last_acq_flags && result.valid_record && channel==0;
    if(channel!=0) { result.candidates=result.accepted=result.stored=0; }
    if(!restore_capture_adc()) { last_acq_flags|=ACQ_TIMEOUT; pending_usable=false; pending_calibrated=false; cal_window_accepted=false; clear_calibration(); }
    if(!strcmp(tag,"STAGE")) clear_calibration();
    memcpy(pending_token,token,33);
    strcpy(pending_tag,tag);
    pending_crc=sb_crc32(samples,last_n);
    pending=true;
    printf("SB1 READY %s\n",token);
}
static void capture(const char *tag,const char *token) { capture_channel(tag,token,0,false); }
static void transfer_record(bool binary) {
    uint32_t meta_crc=0xffffffffu;
    int n=snprintf(metadata_line,sizeof metadata_line,"SB1 BEGIN %s tag=%s n=%" PRIu32 " sample_hz=%.6f gain=%s calibration_id=%" PRIu32
           " calibrated=%u acq_flags=%" PRIu32 " quality_flags=%" PRIu32
           " baseline=%.3f baseline_rms=%.3f sigma=%.3f threshold=%.3f tail_baseline_shift=%.3f adc_errors=%" PRIu32 " clipped_samples=%" PRIu32 " usable=%u start_us=%" PRIu64
           " end_us=%" PRIu64 " gap_before_us=%" PRIu64 " observation_samples=%" PRIu32
           " dead_samples=%" PRIu32 " analysis_start=%" PRIu32 " analysis_end=%" PRIu32 " candidates=%" PRIu32 " stored=%" PRIu32 " rate_exposure_valid=0 channel=ADC%" PRIu32 " profile=%s algorithm=2 cal_window_accepted=%u calibration_remaining=%" PRIu32 " calibration_windows=%" PRIu32 " settling_discarded=32 boot_id=%016" PRIx64 " observation_only=%u threshold_origin=%s gain_confirmed=%u\n",
           pending_token,pending_tag,last_n,sample_hz,high_gain?"HIGH":"LOW",pending_calibration_id,
           (unsigned)pending_calibrated,last_acq_flags,result.quality_flags,result.baseline,result.baseline_rms,result.sigma,
           result.threshold,result.tail_baseline_shift,result.adc_errors,result.clipped_samples,(unsigned)pending_usable,start_us,finish_us,gap_before_us,
           result.observation_samples,result.dead_samples,result.analysis_start,result.analysis_end,result.candidates,result.stored,
           pending_channel,processing_polarity==FDS_POLARITY_NEGATIVE?"NEGATIVE":"POSITIVE",(unsigned)cal_window_accepted,calibration_remaining,calibration_windows,boot_identity,(unsigned)pending_observation,(!strcmp(pending_tag,"CAL") || !pending_calibrated)?"record_noise":"frozen_calibration",(unsigned)pending_gain_confirmed);
    if(!emit_metadata(n,&meta_crc))return;
    for(uint32_t i=0;i<result.stored;i++) {
        const fds_event *e=&result.events[i];
        n=snprintf(metadata_line,sizeof metadata_line,"SB1 EVENT %s index=%" PRIu32 " start=%" PRIu32 " peak=%" PRIu32 " end=%" PRIu32
               " delta_codes=%.3f local_baseline=%.3f local_offset=%.3f local_slope=%.3f"
               " local_sigma=%.3f baseline_tolerance=%.3f slope_tolerance=%.3f negative_tail=%.3f above=%" PRIu32 " contiguous=%" PRIu32 " flags=%" PRIu32 " qualified=%u\n",
               pending_token,i,e->start,e->peak,e->end,e->peak_delta_codes,e->local_baseline_codes,
               e->local_offset_codes,e->local_slope_codes,e->local_sigma_codes,e->baseline_tolerance_codes,e->slope_tolerance_codes,e->negative_tail_codes,e->above_threshold_samples,e->contiguous_above_samples,
               e->flags,(unsigned)(pending_usable && !e->flags));
        if(!emit_metadata(n,&meta_crc))return;
    }
    for(uint32_t i=0;i<last_n;i+=128) {
        if(binary) {
            uint32_t count=last_n-i<128?last_n-i:128;
            uint8_t header[6]={(uint8_t)i,(uint8_t)(i>>8),(uint8_t)(i>>16),(uint8_t)(i>>24),(uint8_t)count,(uint8_t)(count>>8)};
            uint8_t bytes[256];
            for(uint32_t j=0;j<count;j++) { bytes[j*2]=(uint8_t)samples[i+j];bytes[j*2+1]=(uint8_t)(samples[i+j]>>8); }
            uint32_t chunk_crc=sb_crc32_bytes_update(0xffffffffu,pending_token,32);
            chunk_crc=sb_crc32_bytes_update(chunk_crc,header,sizeof header);
            chunk_crc=sb_crc32_bytes_update(chunk_crc,bytes,count*2)^0xffffffffu;
            printf("SB1 BINARY %s %" PRIu32 " %" PRIu32 " %08" PRIx32 "\n",pending_token,i,count,chunk_crc);
            fflush(stdout);
            stdio_put_string((const char *)bytes,(int)(count*2),false,false);
            putchar_raw('\n');
            continue;
        }
        int prefix=snprintf(data_line,sizeof data_line,"SB1 DATA %s %" PRIu32 " ",pending_token,i);
        if(prefix<0 || (size_t)prefix+128u*4u+2u>sizeof data_line) {
            puts("SB1 ERROR DATA_OVERFLOW"); return;
        }
        static const char hex[]="0123456789abcdef";
        size_t cursor=(size_t)prefix;
        uint32_t stop=(last_n-i<128)?last_n:i+128;
        for(uint32_t j=i;j<stop;j++) {
            unsigned lo=samples[j]&255u, hi=samples[j]>>8;
            data_line[cursor++]=hex[lo>>4]; data_line[cursor++]=hex[lo&15u];
            data_line[cursor++]=hex[hi>>4]; data_line[cursor++]=hex[hi&15u];
        }
        data_line[cursor++]='\n'; data_line[cursor]='\0';
        fputs(data_line,stdout);
    }
    printf("SB1 META %s %08" PRIx32 "\n",pending_token,meta_crc^0xffffffffu);
    printf("SB1 END %s %" PRIu32 " %08" PRIx32 "\n",pending_token,last_n,pending_crc);
}
static void transfer(void) { transfer_record(false); }
static void command(char *line) {
#ifdef FDS_STREAMING
    if(stream_begin(line))return;
#endif
    char burst_mode[8]={0},burst_channel[8]={0},burst_token[34]={0},burst_extra[2]={0};
    if(!strncmp(line,"SB1 BURST ",10)) {
        int fields=sscanf(line,"SB1 BURST %7s %7s %33s %1s",burst_mode,burst_channel,burst_token,burst_extra);
        if(fields!=3 || (strcmp(burst_mode,"MANUAL") && strcmp(burst_mode,"STAGE")) ||
           strlen(burst_channel)!=4 || strncmp(burst_channel,"ADC",3) || burst_channel[3]<'0' || burst_channel[3]>'2' ||
           (!strcmp(burst_mode,"MANUAL") && strcmp(burst_channel,"ADC0")) || !sb_token_valid(burst_token)) {
            puts("SB1 ERROR BAD_COMMAND");return;
        }
        if(manual_active) { puts("SB1 ERROR MANUAL_ACTIVE");return; }
        if(diagnostic_active) { puts("SB1 ERROR DIAG_ACTIVE");return; }
        if(!adc_restore_ok) { puts("SB1 ERROR ADC_RESTORE_REQUIRED");return; }
        capture_channel(burst_mode,burst_token,(uint32_t)(burst_channel[3]-'0'),false);return;
    }
    char verb[16]={0}, arg[34]={0}, token[34]={0}, extra[2]={0};
    /* A scanf whitespace directive also matches zero characters. Require the
       protocol separator explicitly so malformed text cannot drive a pin. */
    if (strncmp(line,"SB1 ",4)!=0) { puts("SB1 ERROR BAD_COMMAND"); return; }
    int n=sscanf(line,"SB1 %15s %33s %33s %1s",verb,arg,token,extra);
    if(n==1 && !strcmp(verb,"STATUS")) { status(); return; }
    if(n==2 && !strcmp(verb,"DIAG")) {
        if(!strcmp(arg,"ENTER")) {
            if(pending) { puts("SB1 ERROR PENDING"); return; }
            if(manual_active) { puts("SB1 ERROR MANUAL_ACTIVE"); return; }
            if(diagnostic_active) { puts("SB1 ERROR DIAG_ACTIVE"); return; }
            clear_calibration(); fixture_idle(); stage_inputs();
            if(!restore_capture_adc()) { puts("SB1 ERROR ADC_RESTORE"); return; }
            diagnostic_active=true; diagnostic_deadline=time_us_64()+MANUAL_LEASE_US;
            puts("SB1 DIAG state=active lease_ms=5000"); return;
        }
        if(!strcmp(arg,"EXIT")) {
            if(!diagnostic_release()) { puts("SB1 ERROR ADC_RESTORE"); return; }
            puts("SB1 DIAG state=idle lease_ms=0"); return;
        }
    }
    if(n==3 && !strcmp(verb,"DIAG") && !strcmp(arg,"READ")) {
        uint32_t sequence;
        if(!diagnostic_sequence(token,&sequence)) { puts("SB1 ERROR BAD_SEQUENCE"); return; }
        if(!diagnostic_active) { puts("SB1 ERROR DIAG_INACTIVE"); return; }
        diagnostic_read(sequence); return;
    }
    if(n==2 && !strcmp(verb,"MANUAL")) {
        if(!strcmp(arg,"ENTER")) {
            if(pending) { puts("SB1 ERROR PENDING"); return; }
            if(diagnostic_active) { puts("SB1 ERROR DIAG_ACTIVE"); return; }
            if(!adc_restore_ok) { puts("SB1 ERROR ADC_RESTORE_REQUIRED"); return; }
            if(manual_active) { puts("SB1 ERROR MANUAL_ACTIVE"); return; }
            clear_calibration();
            stage_inputs();
            for(uint pin=0;pin<29;pin++) if(MANUAL_PINS&(1u<<pin)) {
                gpio_init(pin); gpio_set_dir(pin,GPIO_IN);
                gpio_disable_pulls(pin); gpio_set_input_enabled(pin,true);
            }
            manual_directions=manual_outputs=0;
            if (!manual_start()) { puts("SB1 ERROR MANUAL_TIMER_UNAVAILABLE"); return; }
            puts("SB1 MANUAL state=active lease_ms=5000"); return;
        }
        if(!strcmp(arg,"EXIT")) {
            manual_release(); puts("SB1 MANUAL state=idle lease_ms=0"); return;
        }
        if(!strcmp(arg,"READ")) {
            if(!manual_active) { puts("SB1 ERROR MANUAL_INACTIVE"); return; }
            manual_live(0, MANUAL_NO_CHANGE); return;
        }
    }
    if(n==3 && !strcmp(verb,"PIN")) {
        if(!manual_active) { puts("SB1 ERROR MANUAL_INACTIVE"); return; }
        /* Strict decimal spelling prevents sscanf accepting a partial number. */
        unsigned pin=0; size_t len=strlen(arg);
        if(!len || len>2 || (len>1 && arg[0]=='0')) { puts("SB1 ERROR BAD_PIN"); return; }
        for(size_t i=0;i<len;i++) {
            if(arg[i]<'0'||arg[i]>'9') { puts("SB1 ERROR BAD_PIN"); return; }
            pin=pin*10u+(unsigned)(arg[i]-'0');
        }
        if(pin>=29 || !(MANUAL_PINS&(1u<<pin))) { puts("SB1 ERROR BAD_PIN"); return; }
        enum manual_pin_action action;
        if (!strcmp(token,"INPUT")) action = MANUAL_INPUT;
        else if (!strcmp(token,"LOW")) action = MANUAL_LOW;
        else if (!strcmp(token,"HIGH")) action = MANUAL_HIGH;
        else { puts("SB1 ERROR BAD_COMMAND"); return; }
        manual_live(pin, action); return;
    }
    if(n==2 && !strcmp(verb,"PROFILE") && (!strcmp(arg,"NEGATIVE") || !strcmp(arg,"POSITIVE"))) {
        if(pending) { puts("SB1 ERROR PENDING");return; }
        if(manual_active || diagnostic_active) { puts("SB1 ERROR MODE_ACTIVE");return; }
        processing_polarity=!strcmp(arg,"NEGATIVE")?FDS_POLARITY_NEGATIVE:FDS_POLARITY_POSITIVE;
        clear_calibration(); status();return;
    }
    if(n==2 && !strcmp(verb,"CALBEGIN")) {
        if(pending) { puts("SB1 ERROR PENDING");return; }
        if(manual_active || diagnostic_active) { puts("SB1 ERROR MODE_ACTIVE");return; }
        if(strlen(arg)!=1 || arg[0]<'1' || arg[0]>'8') { puts("SB1 ERROR BAD_WINDOWS");return; }
        clear_calibration();calibration_windows=calibration_remaining=(uint32_t)(arg[0]-'0');
        printf("SB1 CALIBRATION windows=%" PRIu32 "\n",calibration_windows);return;
    }
    if(n==2 && !strcmp(verb,"GAIN") && (!strcmp(arg,"LOW") || !strcmp(arg,"HIGH"))) {
        if(manual_active) { puts("SB1 ERROR MANUAL_ACTIVE"); return; }
        if(diagnostic_active) { puts("SB1 ERROR DIAG_ACTIVE"); return; }
        if(pending) { puts("SB1 ERROR PENDING"); return; }
        high_gain=!strcmp(arg,"HIGH"); gain_confirmed=true; clear_calibration(); status(); return;
    }
    if(n==3 && !strcmp(verb,"OBSERVE") && (!strcmp(arg,"BACKGROUND") || !strcmp(arg,"SOURCE")) && sb_token_valid(token)) {
        if(manual_active) { puts("SB1 ERROR MANUAL_ACTIVE"); return; }
        if(diagnostic_active) { puts("SB1 ERROR DIAG_ACTIVE"); return; }
        if(!adc_restore_ok) { puts("SB1 ERROR ADC_RESTORE_REQUIRED"); return; }
        capture_channel(arg,token,0,true); return;
    }
    if(n==3 && !strcmp(verb,"CAPTURE") && (!strcmp(arg,"CAL") || !strcmp(arg,"BACKGROUND") || !strcmp(arg,"SOURCE")) && sb_token_valid(token)) {
        if(manual_active) { puts("SB1 ERROR MANUAL_ACTIVE"); return; }
        if(diagnostic_active) { puts("SB1 ERROR DIAG_ACTIVE"); return; }
        if(!adc_restore_ok) { puts("SB1 ERROR ADC_RESTORE_REQUIRED"); return; }
        capture(arg,token); return;
    }
    if(n==2 && !strcmp(verb,"GETB") && sb_token_valid(arg)) {
        if(pending && !strcmp(arg,pending_token)) transfer_record(true); else puts("SB1 ERROR NO_RECORD");
        return;
    }
    if(n==2 && !strcmp(verb,"GET") && sb_token_valid(arg)) {
        if(pending && !strcmp(arg,pending_token)) transfer(); else puts("SB1 ERROR NO_RECORD");
        return;
    }
    if(n==3 && !strcmp(verb,"ACK") && sb_token_valid(arg) && strlen(token)==8) {
        char expected[9];
        if(pending && !strcmp(arg,pending_token)) {
            snprintf(expected,sizeof expected,"%08" PRIx32,pending_crc);
            if(strcmp(expected,token)) { puts("SB1 ERROR CHECKSUM"); return; }
            memcpy(last_ack_token,pending_token,33);last_ack_crc=pending_crc;pending=false;
            printf("SB1 ACKED %s\n",arg);return;
        }
        snprintf(expected,sizeof expected,"%08" PRIx32,last_ack_crc);
        if(!strcmp(arg,last_ack_token) && !strcmp(token,expected)) { printf("SB1 ACKED %s\n",arg);return; }
        puts("SB1 ERROR NO_RECORD");return;
    }
    puts("SB1 ERROR BAD_COMMAND");
}
/* A USB disconnect may leave a truncated line in the parser. '?' is reserved
   as a safe resynchronization probe and never occurs in an SB1 command. */
static void input_char(int c) {
    static char line[128];
    static size_t used;
    static bool overflow,invalid,seen_cr;
    if (c == '?') { manual_release();(void)diagnostic_release();used=0;overflow=invalid=seen_cr=false;hello();return; }
    if (c == '\n') {
        if (overflow) puts("SB1 ERROR TOO_LONG");
        else if (invalid) puts("SB1 ERROR BAD_COMMAND");
        else if (used) { line[used]='\0';command(line); }
        used=0;overflow=invalid=seen_cr=false;return;
    }
    if (c == '\r') { if (seen_cr) invalid=true; seen_cr=true; return; }
    if (seen_cr) invalid=true; /* CR is only accepted immediately before LF. */
    /* Embedded NUL or other controls must not truncate into a valid command. */
    if (c < 0x20 || c > 0x7e) { invalid=true;return; }
    if (used < sizeof(line)-1 && !overflow) line[used++]=(char)c;
    else overflow=true;
}
int main(void) {
    stdio_init_all();boot_us=time_us_64();fixture_idle();
    adc_init();adc_gpio_init(ADC_GPIO);
    stage_inputs();
    gpio_disable_pulls(ADC_GPIO);gpio_set_input_enabled(ADC_GPIO,false);
    adc_select_input(0);adc_set_round_robin(0);adc_set_temp_sensor_enabled(false);
    adc_fifo_setup(true,true,1,true,false);
    uint32_t adc_hz=clock_get_hz(clk_adc);
    uint32_t div256=(uint32_t)lround(((double)adc_hz/REQUESTED_HZ-1)*256);
    sample_clkdiv=div256/256.0f;
    adc_set_clkdiv(sample_clkdiv);
    sample_hz=adc_hz*256.0/(div256+256.0);
    dma_channel=dma_claim_unused_channel(true);
    dma_channel_set_irq0_enabled((uint)dma_channel,true);
    irq_set_exclusive_handler(DMA_IRQ_0,dma_finished);irq_set_enabled(DMA_IRQ_0,true);
#ifdef FDS_STREAMING
    stream_hardware_init();
#endif
    while(true) {
        diagnostic_expire();
#ifdef FDS_STREAMING
        tud_task();
        if(stream_active){stream_service();continue;}
        int c=getchar_timeout_us(0);
#else
        int c=getchar_timeout_us(100000);
#endif
        diagnostic_expire();
        if(c<0)continue;
        input_char(c);
    }
}
