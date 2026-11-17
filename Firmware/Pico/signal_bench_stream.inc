/* Included in the Pico W streaming build. It shares the existing ADC restore,
 * protected pin mask, and interrupt driven Manual lease. */
#include "tusb.h"
#include "pico/stdio_usb.h"
#include "signal_bench_stream_crc.h"
#include "signal_bench_adc_rate.h"
#include "signal_bench_average.h"

#define STREAM_WORDS 2048u
#define STREAM_QUEUE 12u
#define STREAM_GPIO_QUEUE 8u
#define STREAM_HEADER 64u
#define STREAM_CONTROL 24u
#define STREAM_HZ 100000u
#define STREAM_KEEPALIVE_US 5000000u
#define STREAM_DRAIN_US 3000000u

enum stream_kind { STREAM_START=1, STREAM_DATA, STREAM_GPIO, STREAM_END };
enum stream_stop { STREAM_CLEAN=0, STREAM_OVERLOAD, STREAM_FIFO, STREAM_LINK, STREAM_LEASE };
enum stream_control { STREAM_STOP=1, STREAM_PING, STREAM_INPUT, STREAM_LOW, STREAM_HIGH, STREAM_RELEASE };
enum { STREAM_UNKNOWN=1u, STREAM_GPIO_MANUAL=1u };
enum { STREAM_PACK12=1u, STREAM_ERROR_BITMAP=2u, STREAM_AVERAGED=4u };
static uint16_t stream_dma_words[2][STREAM_WORDS] __attribute__((aligned(4096)));
typedef struct {
    uint16_t samples[STREAM_WORDS];
    uint64_t index, time;
} stream_block;
static stream_block stream_queue[STREAM_QUEUE];
static uint32_t stream_crc_table[256];
_Static_assert(sizeof(stream_dma_words) + sizeof(stream_queue) + sizeof(samples) +
               sizeof(workspace) + sizeof(result) + sizeof(stream_crc_table) < 150u * 1024u,
               "Acquisition buffers must fit with bounded USB and stack storage");

static int stream_dma[2];
static uint32_t stream_dma_mask;
static volatile uint32_t stream_head, stream_tail, stream_queue_peak;
static volatile bool stream_armed, stream_stop_requested, stream_acquisition_ended;
static volatile uint32_t stream_end_reason, stream_end_flags;
static volatile uint64_t stream_next_index, stream_end_time;
static bool stream_active, stream_manual, stream_packed, stream_started_sent, stream_end_queued, stream_restore_done;
static uint8_t stream_channel, stream_average;
static bool stream_timing;
static uint32_t stream_max_prepare_us;
static uint64_t stream_usb_wait_start, stream_max_usb_wait, stream_total_usb_wait;
static bool stream_usb_waiting;
static uint32_t stream_rate, stream_adc_clock, stream_div256;
static uint32_t stream_seq;
static uint64_t stream_id, stream_start_time, stream_sent_samples, stream_keepalive, stream_drain_until;
static uint8_t stream_tx[STREAM_HEADER + 2u * STREAM_WORDS];
static size_t stream_tx_size, stream_tx_offset;
static uint8_t stream_rx[STREAM_CONTROL];
static size_t stream_rx_size;
typedef struct {
    uint8_t payload[16];
    uint64_t time, index;
} stream_gpio_event;
static stream_gpio_event stream_gpio[STREAM_GPIO_QUEUE];
static uint32_t stream_gpio_head, stream_gpio_tail;

static void stream_le16(uint8_t *dst, uint16_t value) {
    dst[0]=(uint8_t)value; dst[1]=(uint8_t)(value>>8);
}
static void stream_le32(uint8_t *dst, uint32_t value) {
    for(uint i=0;i<4;i++) dst[i]=(uint8_t)(value>>(i*8));
}
static void stream_le64(uint8_t *dst, uint64_t value) {
    for(uint i=0;i<8;i++) dst[i]=(uint8_t)(value>>(i*8));
}
static uint32_t stream_get32(const uint8_t *src) {
    return (uint32_t)src[0] | ((uint32_t)src[1]<<8) | ((uint32_t)src[2]<<16) | ((uint32_t)src[3]<<24);
}
static uint64_t stream_get64(const uint8_t *src) {
    return (uint64_t)stream_get32(src) | ((uint64_t)stream_get32(src+4)<<32);
}
static uint32_t stream_crc(const void *data,size_t count,uint32_t crc) {
    return sb_stream_crc_update(stream_crc_table,crc,data,count);
}

static void stream_finish_irq(uint32_t reason, uint32_t flags) {
    adc_run(false);
    stream_end_time=time_us_64();
    stream_end_reason=reason;
    stream_end_flags|=flags;
    stream_armed=false;
    stream_acquisition_ended=true;
}
static void stream_dma_interrupt(void) {
    const uint32_t raised=dma_hw->ints1&stream_dma_mask;
    if(!raised)return;
    dma_hw->ints1=raised;
    if(!stream_armed)return;
    if((raised&(raised-1u)) || (adc_hw->fcs&(ADC_FCS_OVER_BITS|ADC_FCS_UNDER_BITS))) {
        stream_finish_irq(STREAM_FIFO,STREAM_UNKNOWN);
        return;
    }
    const uint channel=(raised&(1u<<(uint)stream_dma[0])) ? 0u : 1u;
    const uint32_t head=stream_head;
    if(head-stream_tail>=STREAM_QUEUE) {
        /* This full DMA block is known to exist. Anything past its
         * boundary is outside the recorded span. */
        stream_next_index+=STREAM_WORDS;
        stream_finish_irq(STREAM_OVERLOAD,0);
        return;
    }
    stream_block *slot=&stream_queue[head%STREAM_QUEUE];
    slot->index=stream_next_index;
    slot->time=time_us_64();
    memcpy(slot->samples,stream_dma_words[channel],sizeof(slot->samples));
    __dmb();
    stream_next_index+=STREAM_WORDS;
    stream_head=head+1;
    const uint32_t used=head+1u-stream_tail;
    if(used>stream_queue_peak)stream_queue_peak=used;
    if(stream_stop_requested)stream_finish_irq(STREAM_CLEAN,0);
}
static void stream_hardware_init(void) {
    sb_stream_crc_init(stream_crc_table);
    for(uint i=0;i<2;i++) {
        stream_dma[i]=dma_claim_unused_channel(true);
        stream_dma_mask|=1u<<(uint)stream_dma[i];
        dma_channel_set_irq1_enabled((uint)stream_dma[i],true);
    }
    irq_set_exclusive_handler(DMA_IRQ_1,stream_dma_interrupt);
    irq_set_priority(DMA_IRQ_1,PICO_HIGHEST_IRQ_PRIORITY);
    irq_set_enabled(DMA_IRQ_1,true);
}
static bool stream_restore(void) {
    if(stream_restore_done)return adc_restore_ok;
    const uint32_t state=save_and_disable_interrupts();
    stream_armed=false;
    adc_run(false);
    for(uint i=0;i<2;i++) dma_channel_set_irq1_enabled((uint)stream_dma[i],false);
    restore_interrupts(state);
    // Disable both chain targets before aborting either channel.
    for(uint i=0;i<2;i++) {
        dma_channel_config cfg=dma_get_channel_config((uint)stream_dma[i]);
        channel_config_set_enable(&cfg,false);
        channel_config_set_chain_to(&cfg,(uint)stream_dma[i]);
        dma_channel_set_config((uint)stream_dma[i],&cfg,false);
    }
    for(uint i=0;i<2;i++)dma_channel_abort((uint)stream_dma[i]);
    dma_hw->ints1=stream_dma_mask;
    stream_restore_done=true;
    return restore_capture_adc();
}

static void stream_frame(uint8_t kind,uint32_t flags,uint64_t index,uint64_t at,uint32_t count,
                         uint32_t aux,const void *payload,size_t size) {
    uint8_t *h=stream_tx;
    memcpy(h,"SBS1",4); h[4]=1; h[5]=kind; stream_le16(h+6,STREAM_HEADER);
    stream_le32(h+8,(uint32_t)size);stream_le32(h+12,stream_seq++);
    stream_le64(h+16,stream_id);stream_le64(h+24,boot_identity);
    stream_le64(h+32,index);stream_le64(h+40,at);
    stream_le32(h+48,count);stream_le32(h+52,aux);stream_le32(h+56,flags);
    if(size && payload!=h+STREAM_HEADER) memcpy(h+STREAM_HEADER,payload,size);
    uint32_t crc=stream_crc(h,60,0xffffffffu);
    crc=stream_crc(h+STREAM_HEADER,size,crc)^0xffffffffu;
    stream_le32(h+60,crc);
    stream_tx_size=STREAM_HEADER+size;stream_tx_offset=0;
}
static void stream_sample_frame(const stream_block *block) {
    if(stream_average > 1u) {
        uint8_t *payload=stream_tx+STREAM_HEADER;
        size_t offset=0;
        for(uint i=0;i<STREAM_WORDS;i+=stream_average)
            offset+=sb_average_encode(payload+offset,block->samples+i,stream_average);
        stream_frame(STREAM_DATA,STREAM_AVERAGED,block->index,block->time,STREAM_WORDS/stream_average,0,payload,offset);
        return;
    }
    if(stream_packed) {
        // Only the 12 ADC bits and bit 15 are defined in the RP2040 FIFO.
        // Send the complete 16 bit words if other bits ever appear.
        uint8_t *packed=stream_tx+STREAM_HEADER;
        uint8_t *errors=packed+3u*STREAM_WORDS/2u;
        bool has_errors=false;
        memset(errors,0,STREAM_WORDS/8u);
        for(uint i=0;i<STREAM_WORDS;i+=2u) {
            const uint16_t a=block->samples[i], b=block->samples[i+1u];
            if((a|b)&0x7000u) goto unpacked;
            packed[0]=(uint8_t)a;
            packed[1]=(uint8_t)(((a>>8)&15u)|(b<<4));
            packed[2]=(uint8_t)(b>>4);
            packed+=3;
            if((a|b)&0x8000u) {
                has_errors=true;
                errors[i/8u]|=(uint8_t)(((a>>15)|((b>>15)<<1))<<(i%8u));
            }
        }
        stream_frame(STREAM_DATA,STREAM_PACK12|(has_errors?STREAM_ERROR_BITMAP:0u),
                     block->index,block->time,STREAM_WORDS,0,stream_tx+STREAM_HEADER,
                     3u*STREAM_WORDS/2u+(has_errors?STREAM_WORDS/8u:0u));
        return;
    }
unpacked:
    stream_frame(STREAM_DATA,0,block->index,block->time,STREAM_WORDS,0,block->samples,sizeof block->samples);
}
static void stream_pin_snapshot(bool release) {
    if(stream_gpio_head-stream_gpio_tail>=STREAM_GPIO_QUEUE) {
        /* Keep the final input state even if the host stalled before seeing
         * earlier snapshots. The stream ending identifies an unknown span. */
        if(!release)return;
        stream_gpio_tail++;
        const uint32_t irq=save_and_disable_interrupts();
        stream_end_flags|=STREAM_UNKNOWN;
        restore_interrupts(irq);
    }
    stream_gpio_event *event=&stream_gpio[stream_gpio_head%STREAM_GPIO_QUEUE];
    const uint32_t state=save_and_disable_interrupts();
    event->time=time_us_64();
    event->index=stream_next_index;
    stream_le32(event->payload,manual_directions);
    stream_le32(event->payload+4,gpio_get_all()&MANUAL_PINS);
    stream_le32(event->payload+8,manual_outputs);
    stream_le32(event->payload+12,manual_active?STREAM_GPIO_MANUAL:0);
    restore_interrupts(state);
    stream_gpio_head++;
}
static void stream_request_stop(void) {
    manual_release();
    if(stream_manual)stream_pin_snapshot(true);
    stream_stop_requested=true;
}
static void stream_failsafe(uint32_t reason) {
    manual_release();
    if(stream_manual)stream_pin_snapshot(true);
    const uint32_t state=save_and_disable_interrupts();
    if(stream_armed)stream_finish_irq(reason,STREAM_UNKNOWN);
    restore_interrupts(state);
}
static void stream_apply_control(const uint8_t *frame) {
    if(frame[4]!=1 || frame[7]!=0 || stream_get32(frame+16)!=0 ||
       stream_get64(frame+8)!=stream_id || stream_get32(frame+20)!=(stream_crc(frame,20,0xffffffffu)^0xffffffffu))return;
    uint8_t op=frame[5],pin=frame[6];
    if(op==STREAM_STOP && pin==0){stream_request_stop();return;}
    if(!stream_armed || stream_stop_requested)return;
    if(op==STREAM_RELEASE && pin==0 && stream_manual){manual_release();stream_pin_snapshot(true);return;}
    if(op==STREAM_PING && pin==0) {
        uint32_t state=save_and_disable_interrupts();
        const uint64_t now=time_us_64();
        stream_keepalive=now+STREAM_KEEPALIVE_US;
        if(manual_active && now<manual_deadline)manual_deadline=stream_keepalive;
        restore_interrupts(state);
        if(stream_manual && stream_gpio_head-stream_gpio_tail<STREAM_GPIO_QUEUE-1u)stream_pin_snapshot(false);
        return;
    }
    if(!stream_manual || pin>=29 || !(MANUAL_PINS&(1u<<pin)) || op<STREAM_INPUT || op>STREAM_HIGH)return;
    if(stream_gpio_head-stream_gpio_tail>=STREAM_GPIO_QUEUE-1u) {
        stream_failsafe(STREAM_OVERLOAD);
        return;
    }
    const uint32_t state=save_and_disable_interrupts();
    if(manual_active && time_us_64()<manual_deadline) {
        const uint32_t bit=1u<<pin;
        if(op==STREAM_INPUT) {
            gpio_set_dir(pin,GPIO_IN); gpio_disable_pulls(pin);
            manual_directions&=~bit; manual_outputs&=~bit;
        } else {
            gpio_put(pin,op==STREAM_HIGH); gpio_set_dir(pin,GPIO_OUT);
            manual_directions|=bit;
            if(op==STREAM_HIGH)manual_outputs|=bit;else manual_outputs&=~bit;
        }
    }
    restore_interrupts(state);
    stream_pin_snapshot(false);
}
static void stream_receive(void) {
    /* A fixed-size control message and bounded resynchronization. */
    static const uint8_t magic[4]={'S','B','C','1'};
    for(uint budget=0;budget<128 && tud_cdc_available();budget++) {
        const int32_t c=tud_cdc_read_char();
        if(c<0)break;
        if(stream_rx_size<4 && (uint8_t)c!=magic[stream_rx_size]) {
            stream_rx_size=0;
            if((uint8_t)c==magic[0])stream_rx[stream_rx_size++]=(uint8_t)c;
            continue;
        }
        stream_rx[stream_rx_size++]=(uint8_t)c;
        if(stream_rx_size==sizeof stream_rx) {
            stream_apply_control(stream_rx);
            stream_rx_size=0;
        }
    }
}
static void stream_drop_link(void) {
    stream_failsafe(STREAM_LINK);
    (void)stream_restore();
    tud_cdc_write_clear();
    stream_active=false;
}
static void stream_usb_wait_finish(uint64_t now) {
    if(!stream_usb_waiting)return;
    const uint64_t wait=now-stream_usb_wait_start;
    if(wait>stream_max_usb_wait)stream_max_usb_wait=wait;
    stream_total_usb_wait+=wait;
    stream_usb_waiting=false;
}

static void stream_service(void) {
    if(!stdio_usb_connected()) {stream_drop_link();return;}
    stream_receive();
    const uint64_t now=time_us_64();
    if(stream_armed && now>=stream_keepalive)stream_failsafe(STREAM_LEASE);
    if(stream_acquisition_ended && !stream_drain_until) {
        if(stream_manual && manual_active) {
            manual_release();stream_pin_snapshot(true);
        }
        if(!stream_restore())stream_end_flags|=STREAM_UNKNOWN;
        stream_drain_until=now+STREAM_DRAIN_US;
    }
    if(stream_drain_until && now>=stream_drain_until){stream_drop_link();return;}
    if(stream_tx_offset==stream_tx_size) {
        if(stream_end_queued){stream_active=false;return;}
        if(!stream_started_sent) {
            uint8_t configuration[12];
            stream_le32(configuration,stream_adc_clock);stream_le32(configuration+4,stream_div256);
            stream_le32(configuration+8,stream_average);
            stream_frame(STREAM_START,stream_channel,0,stream_start_time,0,stream_rate,configuration,stream_average>1u?12u:8u);
            stream_started_sent=true;
        } else if(stream_gpio_tail!=stream_gpio_head) {
            const stream_gpio_event *event=&stream_gpio[stream_gpio_tail%STREAM_GPIO_QUEUE];
            stream_frame(STREAM_GPIO,0,event->index,event->time,0,0,event->payload,sizeof event->payload);
            stream_gpio_tail++;
        } else if(stream_tail!=stream_head) {
            __dmb();
            const stream_block *block=&stream_queue[stream_tail%STREAM_QUEUE];
            const uint64_t began=stream_timing?time_us_64():0;
            stream_sample_frame(block);
            if(stream_timing) {
                const uint32_t elapsed=(uint32_t)(time_us_64()-began);
                if(elapsed>stream_max_prepare_us)stream_max_prepare_us=elapsed;
            }
            __dmb();
            stream_tail++;
            stream_sent_samples+=STREAM_WORDS/stream_average;
        } else if(stream_acquisition_ended) {
            uint8_t totals[32];stream_le64(totals,stream_sent_samples);
            stream_le32(totals+8,stream_queue_peak);
            stream_le32(totals+12,stream_max_prepare_us);
            stream_le64(totals+16,stream_max_usb_wait);
            stream_le64(totals+24,stream_total_usb_wait);
            stream_frame(STREAM_END,stream_end_flags,stream_next_index,stream_end_time,0,stream_end_reason,totals,stream_timing?32u:12u);
            stream_end_queued=true;
        }
    }
    size_t count=stream_tx_size-stream_tx_offset;
    const uint32_t capacity=tud_cdc_write_available();
    if(count>capacity)count=capacity;
    const uint32_t written=count?tud_cdc_write(stream_tx+stream_tx_offset,(uint32_t)count):0;
    if(stream_timing) {
        if(written)stream_usb_wait_finish(now);
        else if(!stream_usb_waiting && stream_tx_offset<stream_tx_size && !stream_end_queued) {
            stream_usb_wait_start=now;
            stream_usb_waiting=true;
        }
    }
    stream_tx_offset+=written;
    (void)tud_cdc_write_flush();
}

static bool stream_begin(const char *line) {
    if(strncmp(line,"SB1 STREAM ",11)!=0)return false;
    char token[17]={0}, mode[9]={0}; uint channel=0, rate=0, average=1;
    int end=0;
    if(sscanf(line,"SB1 STREAM %16[0-9a-f] %1u %8s %6u%n",token,&channel,mode,&rate,&end)!=4) {
        puts("SB1 ERROR BAD_STREAM");return true;
    }
    const char *suffix=line+end;
    const bool averaged=!strncmp(suffix," AVG1 ",6);
    if(averaged && (sscanf(suffix," AVG1 %2u",&average)!=1 || !sb_average_valid_factor(average))) {
        puts("SB1 ERROR BAD_STREAM");return true;
    }
    const bool packed=!averaged && rate>250000u;
    const bool timing=averaged || !strcmp(suffix,packed?" PACK12 METRICS":" METRICS");
    if(strlen(token)!=16 || channel>2 ||
       (strcmp(mode,"RAW") && strcmp(mode,"MANUAL") && strcmp(mode,"DIAG")) ||
       (strcmp(mode,"DIAG") && channel!=0) ||
       (rate<10000u || rate>500000u)) {puts("SB1 ERROR BAD_STREAM");return true;}
    char canonical[96];
    int prefix=snprintf(canonical,sizeof canonical,"SB1 STREAM %s %u %s %u",token,channel,mode,rate);
    if(averaged)snprintf(canonical+prefix,sizeof canonical-(size_t)prefix," AVG1 %u",average);
    else snprintf(canonical+prefix,sizeof canonical-(size_t)prefix,"%s%s",packed?" PACK12":"",timing?" METRICS":"");
    if(strcmp(canonical,line) || pending || diagnostic_active || manual_active || !adc_restore_ok) {
        puts("SB1 ERROR STREAM_UNAVAILABLE");return true;
    }
    const uint32_t adc_clock=clock_get_hz(clk_adc);
    uint32_t divider=0;
    if(!sb_stream_adc_divider256(adc_clock,rate,&divider)) {puts("SB1 ERROR ADC_RATE_UNAVAILABLE");return true;}
    if(!stopped_fifo_drain()) {puts("SB1 ERROR ADC_RESTORE_REQUIRED");return true;}
    if(!boot_identity){boot_identity=get_rand_64();if(!boot_identity)boot_identity=1;}
    stream_id=strtoull(token,NULL,16);
    if(!stream_id){puts("SB1 ERROR BAD_STREAM");return true;}
    stream_manual=!strcmp(mode,"MANUAL");
    if(stream_manual) {
        for(uint pin=0;pin<29;pin++)if(MANUAL_PINS&(1u<<pin)){
            gpio_init(pin);gpio_set_dir(pin,GPIO_IN);gpio_disable_pulls(pin);gpio_set_input_enabled(pin,true);
        }
        manual_directions=manual_outputs=0;
        if(!manual_start()) {puts("SB1 ERROR MANUAL_TIMER_UNAVAILABLE");return true;}
    }
    clear_calibration();
    stream_channel=(uint8_t)channel;stream_rate=rate;stream_adc_clock=adc_clock;stream_packed=packed;
    stream_average=(uint8_t)average;stream_timing=timing;
    stream_max_prepare_us=0;stream_max_usb_wait=stream_total_usb_wait=0;stream_usb_waiting=false;
    stream_div256=divider;
    adc_select_input(channel);adc_set_round_robin(0);adc_set_clkdiv(stream_div256/256.0f);
    adc_fifo_setup(true,true,1,true,false);
    if(discard_warmup()) {manual_release();(void)restore_capture_adc();puts("SB1 ERROR ADC_WARMUP");return true;}
    adc_hw->fcs|=ADC_FCS_OVER_BITS|ADC_FCS_UNDER_BITS;
    adc_hw->cs|=ADC_CS_ERR_STICKY_BITS;
    stream_head=stream_tail=stream_seq=stream_queue_peak=0;
    stream_next_index=stream_sent_samples=0;
    stream_tx_size=stream_tx_offset=stream_rx_size=0;
    stream_started_sent=stream_end_queued=stream_stop_requested=stream_acquisition_ended=stream_restore_done=false;
    stream_gpio_head=stream_gpio_tail=0;stream_end_flags=0;stream_end_reason=STREAM_CLEAN;stream_drain_until=0;
    dma_hw->ints1=stream_dma_mask;
    for(uint i=0;i<2;i++) {
        const uint ch=(uint)stream_dma[i];
        dma_channel_config cfg=dma_channel_get_default_config(ch);
        channel_config_set_transfer_data_size(&cfg,DMA_SIZE_16);
        channel_config_set_read_increment(&cfg,false);
        channel_config_set_write_increment(&cfg,true);
        channel_config_set_ring(&cfg,true,12);
        channel_config_set_dreq(&cfg,DREQ_ADC);
        channel_config_set_chain_to(&cfg,(uint)stream_dma[1-i]);
        dma_channel_configure(ch,&cfg,stream_dma_words[i],&adc_hw->fifo,STREAM_WORDS,false);
        dma_channel_set_irq1_enabled(ch,true);
    }
    stream_active=stream_armed=true;
    dma_start_channel_mask(1u<<(uint)stream_dma[0]);
    stream_start_time=time_us_64();
    stream_keepalive=stream_start_time+STREAM_KEEPALIVE_US;
    adc_run(true);
    if(stream_manual && stream_gpio_head-stream_gpio_tail<STREAM_GPIO_QUEUE-1u)stream_pin_snapshot(false);
    return true;
}
