from pathlib import Path
import sys,shutil,subprocess,json,os
F=Path(__file__).resolve().parents[1];O=Path(sys.argv[1]).resolve()
O.mkdir(parents=True,exist_ok=True)
for name in ['tmp','ModuleCache']:(O/name).mkdir(exist_ok=True)
os.environ['TMPDIR']=str(O/'tmp');os.environ['CLANG_MODULE_CACHE_PATH']=str(O/'ModuleCache')
# API syntax stubs only: do not masquerade as Arduino core or actual AVR compile.
stub=O/'Stubs';stub.mkdir(exist_ok=True)
(stub/'Arduino.h').write_text('''#include <stdint.h>
#define _BV(x) (1U<<(x))
#define F(x) x
#define INPUT 0
#define LOW 0
#define A0 14
#define DEFAULT 1
#define ADIF 4
#define REFS0 6
#define ADC0D 0
#define ADEN 7
#define ADATE 5
#define ADPS2 2
#define ADPS1 1
#define ADPS0 0
#define ADSC 6
extern uint8_t ADCSRA,ADMUX,ADCSRB,DIDR0;
extern uint16_t ADC;
void delay(unsigned long);unsigned long micros();void pinMode(int,int);void digitalWrite(int,int);void analogReference(int);
struct SerialStub {void begin(long);void flush();int available();int read();template<class T>void print(T){} template<class T>void print(T,int){} template<class T>void println(T){} };extern SerialStub Serial;
''')
logs=[]
for sanitizer in [False,True]:
 exe=O/('avr_core_sanitized' if sanitizer else 'avr_core_optimized');cmd=['clang++','-std=c++11','-Wall','-Wextra','-Werror','-O1' if sanitizer else '-O2',str(F/'tests/test_avr_detector.cpp'),'-o',str(exe)]
 if sanitizer:cmd+=['-fsanitize=address,undefined','-fno-omit-frame-pointer']
 r=subprocess.run(cmd,text=True,capture_output=True);assert r.returncode==0,r.stderr
 r=subprocess.run([str(exe)],text=True,capture_output=True);assert r.returncode==0,r.stdout+r.stderr;logs.append(dict(scope='AVR algorithm native host '+('ASan/UBSan' if sanitizer else 'optimized'),result=r.stdout.strip()))
for board in ['UNO','NANO']:
 cmd=['clang++','-x','c++','-std=c++11','-fsyntax-only','-Wall','-Wextra','-Werror','-D__AVR_ATmega328P__','-DF_CPU=16000000UL','-DARDUINO_AVR_'+board,'-I'+str(stub),str(F/'Arduino/RevE_Arduino/RevE_Arduino.ino')]
 r=subprocess.run(cmd,text=True,capture_output=True);assert r.returncode==0,r.stderr;logs.append(dict(scope='Arduino '+board+' native C++ syntax with API/register stubs; NOT AVR/core linkage',result='PASS'))
# Verify application capture state size with the real estimator declarations.
(O/'ram.c').write_text('#include <stdio.h>\n#include "'+str(F/'pulse_estimator.h')+'"\nint main(){printf("%zu\\n",32768*sizeof(uint16_t)+sizeof(fds_workspace)+sizeof(fds_result));}\n')
r=subprocess.run(['clang','-std=c11',str(O/'ram.c'),'-o',str(O/'ram')],text=True,capture_output=True);assert not r.returncode,r.stderr
state=int(subprocess.check_output([str(O/'ram')],text=True));assert state<80*1024
record={'status':'PASS: portable algorithm and syntax/resource checks only','checks':logs,'pico_capture_static_bytes_native_ABI':state,'RP2040_SRAM_bytes':264*1024,'application_capture_state_limit_bytes':80*1024,'AVR_capture_samples':256,'AVR_application_state_limit_bytes':800,'actual_target_builds':{b:'NOT RUN - installed target SDK/core/toolchain unavailable' for b in ['pico','pico_w','pico2','pico2_w','UnoR3','NanoClassic']},'hardware_programmed':False,'hardware_tested':False,'toolchain_preflight':{n:shutil.which(n) for n in ['cmake','arm-none-eabi-gcc','avr-g++','arduino-cli']},'limits':['Native ABI is not an ARM/AVR link map; actual total firmware/linker/stack use must be checked on target.','Arduino stub syntax check does not validate register semantics, real Arduino APIs or timing on hardware.','Radio/host rail ripple, baseline noise, stability, clipping, radiation response and power transitions remain unmeasured.']}
(O/'Host Compatibility Verification.json').write_text(json.dumps(record,indent=2)+'\n');print(json.dumps(record,indent=2))
