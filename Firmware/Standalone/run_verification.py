"""Run existing native tools only. No SDK/core installation, fetch or programming."""
from pathlib import Path
import hashlib,json,os,re,shutil,subprocess,sys
source=Path(__file__).resolve().parent
if len(sys.argv)!=2:raise SystemExit('Usage: python3 run_verification.py OUTPUT_DIRECTORY')
out=Path(sys.argv[1]).resolve()
out.mkdir(parents=True,exist_ok=True)
for name in ['tmp','ModuleCache']:(out/name).mkdir(exist_ok=True)
os.environ['TMPDIR']=str(out/'tmp');os.environ['CLANG_MODULE_CACHE_PATH']=str(out/'ModuleCache')
tools={name:shutil.which(name) for name in ['clang','clang++','cmake','ninja','arm-none-eabi-gcc','avr-g++','arduino-cli']}
sdk=os.environ.get('PICO_SDK_PATH')
checks={'date':'2026-10-27','tool_preflight':tools,'PICO_SDK_PATH':sdk,
 'existing_SDK_configured':bool(sdk and (Path(sdk)/'external/pico_sdk_import.cmake').is_file()),
 'target_compile':{b:'NOT RUN; no installed target SDK/core/toolchain available in recorded preflight' for b in ['pico','pico_w','pico2','pico2_w','uno','nano']},
 'hardware_programmed':False,'hardware_tested':False,
 'scope':'Native synthetic processing, declaration-stub syntax/format and timeout control-flow simulation only; NOT MCU SDK/core/target build',
 'commands':[]}
failures=0
def run(label,cmd):
 global failures
 p=subprocess.run(cmd,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 (out/(label+'.log')).write_text(p.stdout)
 checks['commands'].append({'label':label,'command':cmd,'returncode':p.returncode})
 print(label+': '+('PASS' if not p.returncode else 'FAIL'))
 if p.returncode:print(p.stdout)
 failures+=p.returncode!=0
 return p.stdout
host=run('Pico Processing',['sh',str(source/'tests/run_host_tests.sh'),str(out/'Host Tests')])
checks['pico_processing_assertions_per_configuration']=[int(v) for v in re.findall(r'assertions=(\d+)',host)]
run('Host Compatibility',[sys.executable,str(source/'tests/check_host_compatibility.py'),str(out/'Host Compatibility')])
run('Pico Native Syntax',[sys.executable,str(source/'tests/check_pico_syntax.py'),str(out/'Pico Native Syntax')])
run('Pico Warmup',[sys.executable,str(source/'tests/check_pico_warmup.py'),str(out/'Pico Warmup')])
harness=source/'tests/avr_timeout'
for sanitized,board in [(False,'UNO'),(True,'NANO')]:
 label='AVR Timeout '+('Sanitized' if sanitized else 'Optimized')
 exe=out/('avr_timeout_sanitized' if sanitized else 'avr_timeout_optimized')
 cmd=['clang++','-std=c++11','-Wall','-Wextra','-Werror','-O1' if sanitized else '-O2','-D__AVR_ATmega328P__','-DF_CPU=16000000UL','-DARDUINO_AVR_'+board,'-I'+str(harness),str(harness/'test_timeout.cpp'),'-o',str(exe)]
 if sanitized:cmd+=['-fsanitize=address,undefined','-fno-omit-frame-pointer']
 run(label+' Compile',cmd)
 if exe.exists():run(label,[str(exe)])
checks['source_SHA256']={str(p.relative_to(source)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(source.rglob('*')) if p.is_file() and '__pycache__' not in p.parts}
checks['limitations']=['Nominal linear cascade and quantization are not actual analog component/noise/tolerance/ADC calibration tests.',
 'Qualified candidates can still contain mutually unresolved pulses, coincident disturbance or hidden upstream clipping.',
 'Long exclusion, restricted trigger windows, record rejection and blind gaps prevent an unbiased rate/exposure claim.',
 'All six target builds, link maps/stack, timing, rails, ADC noise and bench charge/source tests remain required.']
checks['status']='PASS' if not failures else 'FAIL'
(out/'Verification.json').write_text(json.dumps(checks,indent=2)+'\n')
print('All six MCU target builds NOT RUN; no installation/download/programming performed.')
raise SystemExit(bool(failures))
