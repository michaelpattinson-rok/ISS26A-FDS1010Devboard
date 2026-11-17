/* Native control-flow test with fabricated SDK registers, not a Pico test. */
#include <assert.h>
#include <stdarg.h>
#include <stdio.h>
static int fake_printf(const char *format, ...) __attribute__((format(printf,1,2)));
#define printf fake_printf
#define main signal_bench_device_main
#include "../signal_bench_main.c"
#undef main
#undef printf
int putchar_raw(int c){return putchar(c);}
int stdio_put_string(const char *s,int n,bool newline,bool cr_translation){assert(!newline && !cr_translation);return (int)fwrite(s,1,(size_t)n,stdout);}
uint64_t get_rand_64(void){return UINT64_C(0x123456789abcdef0);}
static dma_hw_t fake_dma; dma_hw_t *dma_hw=&fake_dma;
static adc_hw_t fake_adc; adc_hw_t *adc_hw=&fake_adc;
static bool configured;
static uint32_t fake_directions, fake_outputs, fake_initialized, fake_ever_driven;
static uint64_t fake_time;
static bool fake_adc_timeout, fake_manual_adc_error, fake_final_ready_timeout;
static uint fake_adc_channel, fake_round_robin, fake_fifo_threshold, fake_channel_reads;
static uint fake_reads[3], fake_mux_order[64], fake_mux_count, fake_dma_aborts;
static bool fake_adc_running, fake_dma_irq, fake_fifo_enabled, fake_fifo_dreq, fake_fifo_errors, fake_fifo_shift, fake_temp_sensor;
static uint32_t fake_adc_gpio_mask, fake_channel_timeout, fake_channel_error, fake_channel_overflow;
static bool fake_ready_timeout, fake_drain_stuck;
static bool fake_capture_stall;
static unsigned fake_capture_noise;
static int fake_capture_pulse;
static bool fake_capture_defects;
static float fake_divider;
static bool fake_irqs_enabled=true, fake_alarm_unavailable, fake_stall_manual_reply;
static alarm_id_t fake_alarm_id, fake_last_alarm_id;
static uint64_t fake_alarm_due;
static int64_t (*fake_alarm_callback)(alarm_id_t,void *);
static void *fake_alarm_context;
static uint fake_unbounded_drains;
void gpio_init(uint x){fake_initialized|=1u<<x;} void gpio_set_dir(uint x,bool b){if(b){fake_directions|=1u<<x;fake_ever_driven|=1u<<x;}else fake_directions&=~(1u<<x);} void gpio_disable_pulls(uint x){(void)x;} void gpio_set_input_enabled(uint x,bool b){(void)x;(void)b;} void gpio_put(uint x,bool b){if(b)fake_outputs|=1u<<x;else fake_outputs&=~(1u<<x);} uint32_t gpio_get_all(void){return fake_outputs;}
void adc_run(bool b){
 const bool was_running=fake_adc_running;
 fake_adc_running=b;
 if(!b){
  if(was_running && manual_active && fake_final_ready_timeout)fake_ready_timeout=true;
  adc_hw->cs=fake_ready_timeout?0:ADC_CS_READY_BITS;return;
 }
 if(configured){configured=false;adc_hw->fcs=0;adc_hw->cs=ADC_CS_READY_BITS;dma_hw->ints0=1u;dma_finished();}
 else if(diagnostic_active){fake_channel_reads=0;adc_hw->fcs=(fake_channel_timeout&(1u<<fake_adc_channel))?ADC_FCS_EMPTY_BITS:0;adc_hw->cs=ADC_CS_READY_BITS;}
 else if(manual_active){
  adc_hw->fcs=fake_adc_timeout?ADC_FCS_EMPTY_BITS:0;
  adc_hw->cs=ADC_CS_READY_BITS;
  adc_hw->fifo=fake_manual_adc_error?0x8000u|1234u:1234u;
 }
 else {adc_hw->fcs=fake_capture_stall?ADC_FCS_EMPTY_BITS:0;adc_hw->cs=ADC_CS_READY_BITS;}
}
void adc_fifo_drain(void){fake_unbounded_drains++;}
uint16_t adc_fifo_get(void){
 if(!fake_adc_running){if(!fake_drain_stuck)adc_hw->fcs=ADC_FCS_EMPTY_BITS;return 0;}
 assert(diagnostic_active && !fake_fifo_dreq && fake_fifo_enabled && fake_round_robin==0 && !fake_temp_sensor);
 assert(fake_adc_channel<3);fake_reads[fake_adc_channel]++;fake_channel_reads++;
 if(fake_channel_reads==33 && (fake_channel_overflow&(1u<<fake_adc_channel)))adc_hw->fcs|=ADC_FCS_OVER_BITS;
 uint16_t code=fake_channel_reads<=32?(uint16_t)(100+fake_adc_channel):(uint16_t)(2000+fake_adc_channel*100);
 return (fake_channel_error&(1u<<fake_adc_channel))?(uint16_t)(code|0x8000u):code;
}
void adc_init(void){} void adc_gpio_init(uint x){fake_adc_gpio_mask|=1u<<x;fake_directions&=~(1u<<x);} void adc_select_input(uint x){fake_adc_channel=x;if(fake_mux_count<64)fake_mux_order[fake_mux_count++]=x;} void adc_set_round_robin(uint x){fake_round_robin=x;} void adc_set_temp_sensor_enabled(bool b){fake_temp_sensor=b;} void adc_fifo_setup(bool a,bool b,uint c,bool d,bool e){fake_fifo_enabled=a;fake_fifo_dreq=b;fake_fifo_threshold=c;fake_fifo_errors=d;fake_fifo_shift=e;adc_hw->fcs=ADC_FCS_EMPTY_BITS;} void adc_set_clkdiv(float f){fake_divider=f;} uint16_t adc_read(void){return 0;}
dma_channel_config dma_channel_get_default_config(uint x){(void)x; return (dma_channel_config){0};}
void channel_config_set_transfer_data_size(dma_channel_config*x,uint y){(void)x;(void)y;} void channel_config_set_read_increment(dma_channel_config*x,bool y){(void)x;(void)y;} void channel_config_set_write_increment(dma_channel_config*x,bool y){(void)x;(void)y;} void channel_config_set_dreq(dma_channel_config*x,uint y){(void)x;(void)y;}
void dma_channel_configure(uint x,const dma_channel_config*y,void *out,const volatile void *in,uint32_t n,bool z){(void)x;(void)y;(void)in;(void)z;uint16_t*p=out;for(uint32_t i=0;i<n;i++)p[i]=(uint16_t)(2048+(i&1?(int)fake_capture_noise:-(int)fake_capture_noise)+(i>=6000 && i<6050?fake_capture_pulse:0));if(fake_capture_defects && n>5000){p[4000]=0x8000u|2048u;p[5000]=4095;}dma_hw->ch[0].transfer_count=0;configured=true;}
void dma_channel_set_irq0_enabled(uint x,bool y){(void)x;fake_dma_irq=y;} void dma_channel_abort(uint x){(void)x;fake_dma_aborts++;configured=false;} int dma_claim_unused_channel(bool b){(void)b;return 0;} void irq_set_exclusive_handler(uint x,void(*f)(void)){(void)x;(void)f;} void irq_set_enabled(uint x,bool y){(void)x;(void)y;} uint32_t clock_get_hz(uint x){(void)x;return 48000000;} void tight_loop_contents(void){} void sleep_ms(uint32_t x){(void)x;} void stdio_init_all(void){} int getchar_timeout_us(uint32_t x){(void)x;return -1;}
/* Run the alarm in simulated IRQ context, including while the command loop is
   stopped. A callback can itself read the clock without re-entering the IRQ. */
static void service_alarm(void) {
 if (!fake_irqs_enabled || !fake_alarm_id || fake_time < fake_alarm_due) return;
 fake_irqs_enabled = false;
 const int64_t delay = fake_alarm_callback(fake_alarm_id, fake_alarm_context);
 assert(delay >= 0);
 if (delay > 0) fake_alarm_due = fake_time + (uint64_t)delay;
 else fake_alarm_id = 0;
 fake_irqs_enabled = true;
}
static int fake_printf(const char *format, ...) {
 if(fake_stall_manual_reply && !strncmp(format,"SB1 LIVE ",9)) {
  assert(fake_irqs_enabled && manual_active && fake_directions);
  fake_time=manual_deadline;
  service_alarm();
  assert(!manual_active && !fake_alarm_id && fake_directions==0);
 }
 va_list args;
 va_start(args,format);
 const int result=vprintf(format,args);
 va_end(args);
 return result;
}
uint64_t time_us_64(void){++fake_time;service_alarm();return fake_time;}
uint32_t save_and_disable_interrupts(void){const bool previous=fake_irqs_enabled;fake_irqs_enabled=false;return previous;}
void restore_interrupts(uint32_t state){fake_irqs_enabled=state;service_alarm();}
alarm_id_t add_alarm_in_us(uint64_t delay,int64_t(*callback)(alarm_id_t,void*),void *context,bool fire_if_past){
 (void)fire_if_past;
 if(fake_alarm_unavailable)return -1;
 assert(!fake_alarm_id && !fake_irqs_enabled);
 fake_alarm_due=fake_time+delay;fake_alarm_callback=callback;fake_alarm_context=context;
 fake_alarm_id=++fake_last_alarm_id;
 return fake_alarm_id;
}
bool cancel_alarm(alarm_id_t id){
 if(id!=fake_alarm_id)return false;
 fake_alarm_id=0;
 return true;
}
static void run(const char *s){char buf[128];assert(strlen(s)<sizeof buf);strcpy(buf,s);command(buf);}
static void burst_tests(void);
static void observation_tests(void);
int main(int argc,char **argv){
 (void)argv;
 const uint16_t v[]={0x3231,0x3433,0x3635,0x3837}; assert(sb_crc32(v,4)==0x9ae0daafu);assert(sb_crc32(v,0)==0);
 assert(sb_token_valid("0123456789abcdef0123456789abcdef"));assert(!sb_token_valid("0123456789ABCDEF0123456789abcdef"));
 sample_hz=100000;sample_clkdiv=479.0f;dma_channel=0;
 run("SB1 CAPTURE BACKGROUND 0123456789abcdef0123456789abcdef");assert(!pending);
 run("SB1 CAPTURE CAL 0123456789abcdef0123456789abcdef");assert(!pending);
 run("SB1 GAIN LOW");assert(gain_confirmed);
 /* A partial command or overflow from an interrupted connection must not
    consume the next safe '?' handshake or execute an abandoned command. */
 const char *partial="SB1 GAIN HIGH";
 for(size_t i=0;i<strlen(partial);i++) input_char(partial[i]);
 input_char('?');input_char('\n');assert(!high_gain && gain_confirmed);
 for(int i=0;i<140;i++) input_char('x');
 input_char('?');input_char('\n');assert(!high_gain);
 run("SB1 CAPTURE CAL 0123456789abcdef0123456789abcdef");assert(pending && frozen_threshold>0 && last_n==32768);
 run("SB1 MANUAL ENTER");assert(!manual_active && pending && frozen_threshold>0);
 run("SB1 DIAG ENTER");run("SB1 DIAG READ 1");run("SB1 DIAG EXIT");
 assert(!diagnostic_active && pending && frozen_threshold>0 && last_n==32768);
 for(size_t i=0;i<strlen(partial);i++) input_char(partial[i]);
 input_char('?');input_char('\n');assert(pending && !high_gain);
 /* Fabricate a diagnostic candidate solely to exercise event wire serialization. */
 result.stored=1;result.candidates=1;result.events[0]=(fds_event){.start=2050,.peak=2051,.end=2060,.peak_delta_codes=42,.local_baseline_codes=2048,.local_sigma_codes=1,.above_threshold_samples=4,.contiguous_above_samples=4};
 /* Verify little-endian output and FIFO error bit across first/last chunk. */
 samples[0]=0x8123; samples[127]=0x0fff; samples[128]=0x00ab; samples[32767]=0x8001;
 pending_crc=sb_crc32(samples,last_n);
 run("SB1 GET 0123456789abcdef0123456789abcdef");
 uint32_t crc=pending_crc;run("SB1 GAIN HIGH");assert(pending && !high_gain);
 run("SB1 CAPTURE CAL ffffffffffffffffffffffffffffffff");assert(pending && !strcmp(pending_token,"0123456789abcdef0123456789abcdef"));
 run("SB1 ACK 0123456789abcdef0123456789abcdef 00000000");assert(pending);
 char ack[100];snprintf(ack,sizeof ack,"SB1 ACK %s %08x",pending_token,crc);run(ack);assert(!pending);run(ack);assert(!pending);
 uint64_t saved_stop=previous_stop_us;
 run("SB1 MANUAL ENTER");assert(manual_active && frozen_threshold==0 && (fake_initialized&MANUAL_PINS)==MANUAL_PINS && !(fake_initialized&((1u<<26)|(1u<<23)|(1u<<24)|(1u<<25)|(1u<<29))));
 run("SB1 PIN 2 HIGH");assert((manual_directions&(1u<<2)) && (fake_outputs&(1u<<2)));
 uint64_t lease=manual_deadline;
 /* Prefixes without the required separator and embedded control bytes must
    never turn a malformed message into an accepted GPIO command. */
 run("SB1PIN 3 HIGH");
 const char *malformed="SB1 PIN 3 HIGH";
 for(size_t i=0;i<strlen(malformed);i++) input_char(malformed[i]);
 input_char(0); input_char('\n');
 const char *split="SB1 P\rIN 3 HIGH\n";
 for(size_t i=0;i<strlen(split);i++) input_char(split[i]);
 assert(manual_active && manual_deadline==lease && fake_directions==(1u<<2));
 run("SB1 PIN 15 HIGH");run("SB1 PIN 26 HIGH");run("SB1 PIN 23 LOW");run("SB1 PIN 29 HIGH");run("SB1 PIN 02 HIGH");
 run("SB1 PIN 27 HIGH");run("SB1 PIN 27 LOW");run("SB1 PIN 27 INPUT");run("SB1 PIN 28 HIGH");run("SB1 PIN 28 LOW");run("SB1 PIN 28 INPUT");
 assert(manual_deadline==lease && fake_directions==(1u<<2));
 run("SB1 DIAG ENTER");assert(manual_active && !diagnostic_active && fake_directions==(1u<<2));
 run("SB1 GAIN HIGH");run("SB1 CAPTURE CAL ffffffffffffffffffffffffffffffff");assert(!pending && !high_gain);
 run("SB1 MANUAL READ");assert(previous_stop_us==saved_stop && manual_deadline>lease);
 /* Renewal reschedules an already queued IRQ. With no subsequent command
    dispatch, the alarm itself releases GPIO at the renewed deadline. */
 fake_time=fake_alarm_due;service_alarm();
 assert(manual_active && fake_directions==(1u<<2) && fake_alarm_due==manual_deadline);
 fake_time=manual_deadline;service_alarm();
 assert(!manual_active && !fake_alarm_id && fake_directions==0);
 run("SB1 MANUAL ENTER");
 fake_stall_manual_reply=true;run("SB1 PIN 2 HIGH");fake_stall_manual_reply=false;
 assert(!manual_active && !fake_alarm_id && fake_directions==0);
 fake_alarm_unavailable=true;run("SB1 MANUAL ENTER");fake_alarm_unavailable=false;
 assert(!manual_active && !fake_alarm_id && fake_directions==0);

 /* Expiry during ADC sampling must defeat an in-progress PIN request even
    if the ADC value is valid. The new output must never be enabled. */
 run("SB1 MANUAL ENTER");run("SB1 PIN 2 HIGH");
 fake_time=fake_alarm_due;service_alarm();assert(fake_alarm_due==manual_deadline);
 fake_ever_driven=0;fake_time=manual_deadline-2;run("SB1 PIN 3 HIGH");
 assert(!manual_active && !fake_alarm_id && fake_directions==0 && fake_ever_driven==0 && adc_restore_ok);

 /* A stuck READY bit, FIFO that never empties, missing sample, error sample
    and failed post-conversion drain each release an existing output and
    block further acquisition until ADC0 restoration succeeds. */
 const uint drains_before_manual_faults=fake_unbounded_drains;
 for (unsigned fault=0; fault<5; fault++) {
  run("SB1 MANUAL ENTER");run("SB1 PIN 2 HIGH");
  assert(manual_active && fake_directions==(1u<<2) && fake_alarm_id);
  fake_ever_driven=0;
  switch (fault) {
   case 0: fake_ready_timeout=true; break;
   case 1: fake_drain_stuck=true;fake_adc.fcs=0; break;
   case 2: fake_adc_timeout=true; break;
   case 3: fake_manual_adc_error=true; break;
   case 4: fake_final_ready_timeout=true; break;
  }
  run("SB1 PIN 3 HIGH");
  assert(!manual_active && !fake_alarm_id && fake_directions==0 && fake_ever_driven==0 && !adc_restore_ok && !fake_adc_running);
  assert(previous_stop_us==saved_stop && fake_unbounded_drains==drains_before_manual_faults);
  run("SB1 MANUAL ENTER");run("SB1 CAPTURE CAL ffffffffffffffffffffffffffffffff");
  assert(!manual_active && !pending);
  fake_ready_timeout=fake_drain_stuck=fake_adc_timeout=fake_manual_adc_error=fake_final_ready_timeout=false;
  input_char('?');
  assert(adc_restore_ok && fake_adc_channel==0 && fake_fifo_dreq);
 }
 run("SB1 MANUAL ENTER");run("SB1 PIN 3 HIGH");assert(fake_directions==(1u<<3));
 const alarm_id_t abandoned=manual_alarm_id;
 input_char('?');assert(!manual_active && !fake_alarm_id && fake_directions==0);
 run("SB1 MANUAL ENTER");
 const char *crlf="SB1 PIN 4 HIGH\r\n";
 for(size_t i=0;i<strlen(crlf);i++) input_char(crlf[i]);
 assert(fake_directions==(1u<<4) && manual_lease_alarm(abandoned,NULL)==0);
 run("SB1 MANUAL EXIT");assert(!manual_active && !fake_alarm_id && fake_directions==0);
 run("SB1 CAPTURE CAL 0123456789abcdef0123456789abcdef");assert(!pending);
 run("SB1 GAIN HIGH");assert(high_gain && frozen_threshold==0);
 run("SB1 CAPTURE SOURCE ffffffffffffffffffffffffffffffff");assert(!pending);
 run("SB1 CAPTURE CAL ffffffffffffffffffffffffffffffff extra");assert(!pending);
 fake_capture_stall=true;
 run("SB1 CAPTURE CAL ffffffffffffffffffffffffffffffff");assert(pending && last_n==0 && last_acq_flags==ACQ_TIMEOUT && frozen_threshold==0);
 run("SB1 GET ffffffffffffffffffffffffffffffff");
 run("SB1 ACK ffffffffffffffffffffffffffffffff 00000000");assert(!pending);fake_capture_stall=false;
 /* Optional J3 channels are input reserved even before/after diagnostics.
    Their former output latch values must never be restored. */
 fake_directions=(1u<<27)|(1u<<28);fake_outputs=fake_directions;stage_inputs();
 uint64_t diagnostic_previous_stop=previous_stop_us;
 assert(fake_directions==0 && (fake_adc_gpio_mask&((1u<<27)|(1u<<28)))==((1u<<27)|(1u<<28)));
 run("SB1 DIAG READ 1");assert(!diagnostic_active);
 frozen_threshold=42;fake_round_robin=7;fake_temp_sensor=true;fake_divider=12;fake_dma_irq=false;
 run("SB1 DIAG ENTER");
 assert(diagnostic_active && !manual_active && frozen_threshold==0 && adc_restore_ok);
 assert(fake_adc_channel==0 && fake_round_robin==0 && !fake_temp_sensor && fake_divider==sample_clkdiv);
 assert(fake_fifo_enabled && fake_fifo_dreq && fake_fifo_threshold==1 && fake_fifo_errors && !fake_fifo_shift && fake_dma_irq && !fake_adc_running && fake_dma_aborts>0);
 uint64_t diagnostic_lease=diagnostic_deadline;
 run("SB1 MANUAL ENTER");run("SB1 GAIN LOW");run("SB1 CAPTURE CAL aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
 assert(diagnostic_active && !manual_active && !pending && high_gain && frozen_threshold==0);
 run("SB1 DIAG READ 0");run("SB1 DIAG READ 01");run("SB1 DIAG READ +1");run("SB1 DIAG READ 4294967296");run("SB1 DIAG READ 99999999999999999999999999999999");run("SB1 DIAG READ 1 extra");
 assert(diagnostic_deadline==diagnostic_lease && fake_reads[0]==0 && fake_reads[1]==0 && fake_reads[2]==0);
 fake_mux_count=0;
 run("SB1 DIAG READ 1");
 assert(fake_reads[0]==33 && fake_reads[1]==33 && fake_reads[2]==33);
 assert(fake_mux_count==4 && fake_mux_order[0]==0 && fake_mux_order[1]==1 && fake_mux_order[2]==2 && fake_mux_order[3]==0);
 assert(fake_adc_channel==0 && fake_fifo_dreq && !fake_adc_running && diagnostic_deadline>diagnostic_lease && previous_stop_us==diagnostic_previous_stop);
 /* All values are independently flagged; an ADC1 timeout must not turn ADC0
    or ADC2 into the missing input, and recovery must restore normal settings. */
 fake_channel_timeout=2;run("SB1 DIAG READ 2");fake_channel_timeout=0;
 fake_channel_error=4;run("SB1 DIAG READ 3");fake_channel_error=0;
 fake_channel_overflow=1;run("SB1 DIAG READ 4");fake_channel_overflow=0;
 run("SB1 DIAG READ 4294967295");
 assert(diagnostic_active && adc_restore_ok && fake_adc_channel==0 && fake_fifo_dreq && fake_directions==0);
 run("SB1 DIAG EXIT");assert(!diagnostic_active && adc_restore_ok && frozen_threshold==0 && fake_directions==0);
 assert(fake_fifo_enabled && fake_fifo_dreq && fake_fifo_errors && !fake_fifo_shift && fake_dma_irq && fake_divider==sample_clkdiv);
 run("SB1 CAPTURE BACKGROUND bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");assert(!pending && frozen_threshold==0);
 run("SB1 DIAG ENTER");fake_time=diagnostic_deadline;diagnostic_expire();
 assert(!diagnostic_active && fake_adc_channel==0 && fake_fifo_dreq && fake_directions==0);
 run("SB1 DIAG ENTER");input_char('?');assert(!diagnostic_active && adc_restore_ok && !fake_adc_running && fake_directions==0);
 /* READY and FIFO-drain faults return rather than hanging. Normal acquisition
    remains blocked until a successful restoration, including resync recovery. */
 run("SB1 DIAG ENTER");fake_ready_timeout=true;run("SB1 DIAG EXIT");
 assert(!diagnostic_active && !adc_restore_ok && frozen_threshold==0);
 run("SB1 MANUAL ENTER");run("SB1 CAPTURE CAL aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");assert(!manual_active && !pending);
 fake_ready_timeout=false;input_char('?');assert(adc_restore_ok);
 run("SB1 DIAG ENTER");fake_drain_stuck=true;adc_hw->fcs=0;run("SB1 DIAG EXIT");assert(!adc_restore_ok && !diagnostic_active);
 fake_drain_stuck=false;input_char('?');assert(adc_restore_ok && fake_adc_channel==0 && fake_fifo_dreq);
 /* A real next capture configures DMA afresh and quiet calibration succeeds
    with the restored ADC0 settings in this fabricated register simulation. */
 run("SB1 CAPTURE CAL aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
 assert(pending && last_n==32768 && last_acq_flags==0 && frozen_threshold>0 && fake_adc_channel==0);
 uint32_t diagnostic_capture_crc=pending_crc;
 run("SB1 DIAG ENTER");assert(pending && !diagnostic_active && pending_crc==diagnostic_capture_crc && frozen_threshold>0);
 snprintf(ack,sizeof ack,"SB1 ACK %s %08x",pending_token,pending_crc);run(ack);assert(!pending);
 if(argc>1){burst_tests();observation_tests();}
 puts("PASS: Signal Bench protocol native CRC, validation, pending, calibration, ACK and gain tests; fake SDK, not hardware");return 0;
}

/* Additional negotiated protocol coverage preserves the original suite above. */
static void acknowledge_current(void) {
 char ack[100];snprintf(ack,sizeof ack,"SB1 ACK %s %08x",pending_token,pending_crc);run(ack);assert(!pending);
}
static void burst_tests(void) {
 assert(!pending && !manual_active && !diagnostic_active);
 run("SB1 PROFILE NEGATIVE");assert(processing_polarity==FDS_POLARITY_NEGATIVE && frozen_threshold==0);
 run("SB1 PROFILE INVALID");assert(processing_polarity==FDS_POLARITY_NEGATIVE);
 run("SB1 CALBEGIN 9");assert(!calibration_remaining);
 run("SB1 CALBEGIN 03");assert(!calibration_remaining);
 run("SB1 CALBEGIN 3");assert(calibration_remaining==3 && frozen_threshold==0);
 uint32_t previous_id=calibration_id;
 const char *tokens[]={"11111111111111111111111111111111","22222222222222222222222222222222","33333333333333333333333333333333"};
 for(uint i=0;i<3;i++) {
  char capture_command[100];snprintf(capture_command,sizeof capture_command,"SB1 CAPTURE CAL %s",tokens[i]);
  fake_capture_noise=i==1?4:1;
  run(capture_command);
  fake_capture_noise=0;
  assert(pending && cal_window_accepted && calibration_remaining==2-i && (frozen_threshold>0)==(i==2));
  assert(calibration_id==previous_id+(i==2));
  run("SB1 PROFILE POSITIVE");assert(processing_polarity==FDS_POLARITY_NEGATIVE);
  acknowledge_current();
 }
 assert(frozen_threshold>35 && frozen_threshold<36); /* Maximum across all accepted quiet windows. */
 run("SB1 BURST MANUAL ADC0 44444444444444444444444444444444");
 assert(pending && pending_channel==0 && pending_usable && pending_calibrated);
 samples[0]=0x800a;samples[1]=0x003f;samples[2]=0x000d;samples[127]=0x0fff;samples[128]=0x00ab;samples[N_SAMPLES-1]=0x8001;
 result.adc_errors=2;result.clipped_samples=2;result.quality_flags=FDS_ADC_ERROR|FDS_CLIPPING;pending_usable=false;
 pending_crc=sb_crc32(samples,last_n);
 puts("BURST_BINARY_START");
 run("SB1 GETB 44444444444444444444444444444444");
 puts("BURST_BINARY_END");
 assert(pending);
 puts("BURST_ASCII_START");run("SB1 GET 44444444444444444444444444444444");puts("BURST_ASCII_END");
 run("SB1 BURST STAGE ADC1 55555555555555555555555555555555");assert(pending_channel==0 && pending);
 acknowledge_current();
 run("SB1 BURST STAGE ADC1 55555555555555555555555555555555");
 assert(pending && pending_channel==1 && !pending_usable && result.candidates==0 && result.stored==0 && frozen_threshold==0);
 assert(fake_adc_channel==0 && fake_fifo_dreq && fake_dma_irq);acknowledge_current();
 run("SB1 BURST MANUAL ADC0 66666666666666666666666666666666");assert(!pending);
 run("SB1 BURST MANUAL ADC1 66666666666666666666666666666666");assert(!pending);
 run("SB1 BURST STAGE ADC3 66666666666666666666666666666666");assert(!pending);
 run("SB1 CALBEGIN 2");run("SB1 CAPTURE CAL 77777777777777777777777777777777");
 assert(pending && cal_window_accepted && calibration_remaining==1);acknowledge_current();
 fake_ready_timeout=true;run("SB1 CAPTURE CAL 88888888888888888888888888888888");fake_ready_timeout=false;
 assert(pending && !cal_window_accepted && frozen_threshold==0 && calibration_remaining==0 && !pending_calibrated);
 acknowledge_current();input_char('?');assert(adc_restore_ok);
 puts("PASS: burst multi-window calibration, profiles, channel restoration and binary preservation");
}

static void observation_tests(void) {
 assert(!pending && !manual_active && !diagnostic_active);
 /* Raw diagnostics can run with no board or declared jumper position. */
 gain_confirmed=false;clear_calibration();
 run("SB1 CAPTURE CAL 90000000000000000000000000000010");assert(!pending);
 run("SB1 CAPTURE BACKGROUND 90000000000000000000000000000010");assert(!pending);
 run("SB1 OBSERVE BACKGROUND 90000000000000000000000000000010");
 assert(pending && pending_observation && !pending_gain_confirmed && !pending_usable && !pending_calibrated && last_n==32768);
 puts("OBSERVE_UNWIRED_BINARY_START");run("SB1 GETB 90000000000000000000000000000010");puts("OBSERVE_UNWIRED_BINARY_END");
 acknowledge_current();assert(!gain_confirmed);
 run("SB1 CAPTURE SOURCE 90000000000000000000000000000011");assert(!pending);
 run("SB1 GAIN LOW");
 /* A rejected quiet record still blocks qualified capture. Raw observations
    remain available with their actual errors and no qualification. */
 fake_capture_noise=100;
 run("SB1 CAPTURE CAL 90000000000000000000000000000001");
 assert(pending && !cal_window_accepted && frozen_threshold==0);
 fake_capture_noise=0;acknowledge_current();
 run("SB1 CAPTURE SOURCE 90000000000000000000000000000002");assert(!pending);
 run("SB1 OBSERVE CAL 90000000000000000000000000000002");assert(!pending);
 run("SB1 OBSERVE SOURCE 90000000000000000000000000000002 extra");assert(!pending);
 run("SB1 MANUAL ENTER");
 run("SB1 OBSERVE SOURCE 90000000000000000000000000000002");assert(!pending);
 run("SB1 MANUAL EXIT");
 run("SB1 DIAG ENTER");
 run("SB1 OBSERVE SOURCE 90000000000000000000000000000002");assert(!pending);
 run("SB1 DIAG EXIT");
 for(unsigned negative=0;negative<2;negative++) {
  run(negative?"SB1 PROFILE NEGATIVE":"SB1 PROFILE POSITIVE");
  fake_capture_pulse=negative?-100:100;
  const char *token=negative?"90000000000000000000000000000004":"90000000000000000000000000000003";
  char request[100];snprintf(request,sizeof request,"SB1 OBSERVE SOURCE %s",token);run(request);
  assert(pending && pending_observation && !pending_usable && !pending_calibrated && pending_calibration_id==0);
  assert(result.candidates==1 && result.stored==1 && result.events[0].flags==0 && last_n==32768);
  assert(frozen_threshold==0 && fake_adc_channel==0 && fake_fifo_dreq && fake_dma_irq);
  const uint32_t saved_crc=pending_crc;
  run(request);assert(pending_crc==saved_crc && pending_observation);
  snprintf(request,sizeof request,"SB1 CAPTURE SOURCE %s",token);run(request);
  assert(pending && pending_crc==saved_crc && pending_observation);
  if(negative) {
   puts("OBSERVE_BINARY_START");snprintf(request,sizeof request,"SB1 GETB %s",token);run(request);puts("OBSERVE_BINARY_END");
  }
  snprintf(request,sizeof request,"SB1 ACK %s 00000000",token);run(request);assert(pending);
  acknowledge_current();
 }
 fake_capture_noise=5;fake_capture_pulse=-100;
 run("SB1 OBSERVE SOURCE 90000000000000000000000000000009");
 assert(pending_observation && !pending_calibrated && !pending_usable && result.candidates==1);
 assert(result.threshold>44 && result.threshold<45); /* Six sigma from this window, not a stale quiet threshold. */
 acknowledge_current();fake_capture_noise=0;
 fake_capture_pulse=0;
 /* Successful old calibration cannot leak qualification into observation. */
 run("SB1 CAPTURE CAL 90000000000000000000000000000005");assert(frozen_threshold>0);acknowledge_current();
 fake_capture_defects=true;
 run("SB1 OBSERVE BACKGROUND 90000000000000000000000000000006");
 assert(pending_observation && !pending_usable && !pending_calibrated && frozen_threshold==0);
 assert((result.quality_flags&(FDS_ADC_ERROR|FDS_CLIPPING))==(FDS_ADC_ERROR|FDS_CLIPPING));
 assert(samples[4000]&0x8000u);acknowledge_current();fake_capture_defects=false;
 run("SB1 CAPTURE BACKGROUND 90000000000000000000000000000007");assert(!pending);
 /* Restoration failure still creates an inspectable, unqualified raw record. */
 fake_ready_timeout=true;run("SB1 OBSERVE SOURCE 90000000000000000000000000000008");fake_ready_timeout=false;
 assert(pending_observation && pending && !pending_usable && !pending_calibrated && last_acq_flags);
 acknowledge_current();input_char('?');assert(adc_restore_ok);
 puts("PASS: observation after rejected calibration, both polarities, per-record noise threshold, protected modes, pending identity, raw ADC defects and restoration failure");
}
