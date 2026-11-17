"""Compile the exact production warmup function with explicit register/time fakes."""
from pathlib import Path
import hashlib,json,os,subprocess,sys
f=Path(__file__).resolve().parents[1]
o=Path(sys.argv[1]).resolve()
o.mkdir(parents=True,exist_ok=True)
for name in ['tmp','ModuleCache']:(o/name).mkdir(exist_ok=True)
os.environ['TMPDIR']=str(o/'tmp');os.environ['CLANG_MODULE_CACHE_PATH']=str(o/'ModuleCache')
s=(f/'main.c').read_text();a=s.index('static uint32_t discard_warmup(void) {');b=s.index('static uint32_t acquire(bool test)',a)
function=s[a:b]
source='''#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <assert.h>
#define ADC_FCS_EMPTY_BITS 8u
#define ACQ_TIMEOUT 1u
struct ADC { volatile uint32_t fcs,fifo; } fake_adc;
static struct ADC *adc_hw=&fake_adc;
static uint64_t tick,step;static unsigned running,drains,loops;static bool release_fifo;
static void adc_run(bool enabled){running=enabled;}
static void adc_fifo_drain(void){drains++;}
static uint64_t time_us_64(void){tick+=step;if(release_fifo&&tick>=1000)fake_adc.fcs=0;return tick;}
static void tight_loop_contents(void){loops++;}
'''+function+'''
static unsigned checks;
#define CHECK(x) do{checks++;assert(x);}while(0)
static void reset(void){tick=0;step=100;running=0;drains=0;loops=0;release_fifo=false;fake_adc.fcs=ADC_FCS_EMPTY_BITS;fake_adc.fifo=2048;}
int main(void){
 reset();CHECK(discard_warmup()==ACQ_TIMEOUT);CHECK(!running);CHECK(drains==2);CHECK(tick>=50000);CHECK(loops<1000);
 reset();step=0;CHECK(discard_warmup()==ACQ_TIMEOUT);CHECK(!running);CHECK(drains==2);CHECK(loops==999999);
 reset();release_fifo=true;CHECK(discard_warmup()==0);CHECK(!running);CHECK(drains==2);CHECK(tick>=1000);
 reset();fake_adc.fcs=0;CHECK(discard_warmup()==0);CHECK(!running);CHECK(drains==2);CHECK(loops==0);
 printf("PASS: Pico extracted production warmup timeout/recovery assertions=%u; fake ADC/time only, NOT SDK/hardware\\n",checks);
 return 0;
}
'''
(o/'warmup_exact_function.c').write_text(source)
checks=[]
for sanitizer in [False,True]:
 exe=o/('warmup_sanitized' if sanitizer else 'warmup_optimized')
 cmd=['clang','-std=c11','-Wall','-Wextra','-Werror','-O1' if sanitizer else '-O2',str(o/'warmup_exact_function.c'),'-o',str(exe)]
 if sanitizer:cmd+=['-fsanitize=address,undefined','-fno-omit-frame-pointer']
 run=subprocess.run(cmd,text=True,capture_output=True)
 if run.returncode:raise SystemExit(run.stderr)
 run=subprocess.run([str(exe)],text=True,capture_output=True)
 (o/('sanitized.log' if sanitizer else 'optimized.log')).write_text(run.stdout+run.stderr)
 if run.returncode:raise SystemExit(run.stdout+run.stderr)
 print(run.stdout,end='')
 checks.append({'sanitized':sanitizer,'returncode':run.returncode,'result':run.stdout.strip()})
(o/'Pico Warmup Verification.json').write_text(json.dumps({'scope':'Exact production function extracted from main.c with fake FIFO/time; not SDK/hardware','function_SHA256':hashlib.sha256(function.encode()).hexdigest(),'checks':checks},indent=2)+'\n')
