"""Native syntax/format checks with DECLARATION STUBS, never an SDK build."""
from pathlib import Path
import json, subprocess, sys, os
f=Path(__file__).resolve().parents[1]
o=Path(sys.argv[1]).resolve()
o.mkdir(parents=True,exist_ok=True)
for name in ['tmp','ModuleCache']:(o/name).mkdir(exist_ok=True)
os.environ['TMPDIR']=str(o/'tmp');os.environ['CLANG_MODULE_CACHE_PATH']=str(o/'ModuleCache')
s=o/'Stubs';s.mkdir(exist_ok=True)
(s/'sdk_stubs.h').write_text('''#include <stdbool.h>
#include <stdint.h>
typedef unsigned int uint;
typedef int alarm_id_t;
typedef struct { uint32_t transfer_count; } dma_ch_t;
typedef struct { uint32_t ints0; dma_ch_t ch[16]; } dma_hw_t;
typedef struct { uint32_t fcs,cs,fifo; } adc_hw_t;
typedef struct { uint32_t unused; } dma_channel_config;
extern dma_hw_t *dma_hw;extern adc_hw_t *adc_hw;
#define GPIO_IN 0
#define GPIO_OUT 1
#define DMA_SIZE_16 1
#define DREQ_ADC 1
#define DMA_IRQ_0 1
#define ADC_FCS_EMPTY_BITS 8
#define ADC_FCS_OVER_BITS 1
#define ADC_FCS_UNDER_BITS 2
#define ADC_CS_ERR_STICKY_BITS 4
#define ADC_CS_READY_BITS 16
#define clk_adc 0
void gpio_init(uint);void gpio_set_dir(uint,bool);void gpio_disable_pulls(uint);void gpio_set_input_enabled(uint,bool);void gpio_put(uint,bool);uint32_t gpio_get_all(void);
void adc_run(bool);void adc_fifo_drain(void);uint16_t adc_fifo_get(void);void adc_init(void);void adc_gpio_init(uint);void adc_select_input(uint);void adc_set_round_robin(uint);void adc_set_temp_sensor_enabled(bool);void adc_fifo_setup(bool,bool,uint,bool,bool);void adc_set_clkdiv(float);uint16_t adc_read(void);
dma_channel_config dma_channel_get_default_config(uint);void channel_config_set_transfer_data_size(dma_channel_config*,uint);void channel_config_set_read_increment(dma_channel_config*,bool);void channel_config_set_write_increment(dma_channel_config*,bool);void channel_config_set_dreq(dma_channel_config*,uint);void dma_channel_configure(uint,const dma_channel_config*,void*,const volatile void*,uint32_t,bool);void dma_channel_set_irq0_enabled(uint,bool);void dma_channel_abort(uint);int dma_claim_unused_channel(bool);
void irq_set_exclusive_handler(uint,void(*)(void));void irq_set_enabled(uint,bool);
uint32_t clock_get_hz(uint);uint64_t time_us_64(void);void tight_loop_contents(void);void sleep_ms(uint32_t);void stdio_init_all(void);int getchar_timeout_us(uint32_t);int putchar_raw(int);int stdio_put_string(const char *,int,bool,bool);uint64_t get_rand_64(void);
alarm_id_t add_alarm_in_us(uint64_t,int64_t(*)(alarm_id_t,void*),void*,bool);bool cancel_alarm(alarm_id_t);
uint32_t save_and_disable_interrupts(void);void restore_interrupts(uint32_t);
''')
headers=['pico/rand.h','pico/stdlib.h','hardware/adc.h','hardware/clocks.h','hardware/dma.h','hardware/gpio.h','hardware/irq.h','hardware/sync.h','hardware/regs/adc.h']
for name in headers:
 p=s/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_text('/* Stub: declarations supplied by forced header. */\n')
checks=[]
for family in ['RP2040','RP2350']:
 for fixture in [0,1]:
  cmd=['clang','-std=c11','-Wall','-Wextra','-Werror','-fsyntax-only','-include',str(s/'sdk_stubs.h'),'-I'+str(s),'-DPICO_'+family+'=1','-DFDS_ENABLE_FIXTURE='+str(fixture),str(f/'main.c')]
  run=subprocess.run(cmd,text=True,capture_output=True)
  checks.append({'family_guard':family,'fixture':fixture,'returncode':run.returncode,'stderr':run.stderr,'scope':'Native syntax/printf format with declaration stubs; NOT Pico SDK build'})
  if run.returncode:print(run.stderr,file=sys.stderr)
(o/'Pico Native Syntax.json').write_text(json.dumps(checks,indent=2)+'\n')
print(json.dumps(checks,indent=2))
raise SystemExit(any(c['returncode'] for c in checks))
