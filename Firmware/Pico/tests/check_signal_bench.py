"""Native fake SDK tests and independent wire CRC check; not an MCU build."""
from pathlib import Path
import os, subprocess, sys, zlib

root = Path(__file__).resolve().parent.parent
out = Path(sys.argv[1]).resolve()
out.mkdir(parents=True, exist_ok=True)
subprocess.run([sys.executable, str(root/'tests/check_pico_syntax.py'), str(out/'syntax')], check=True, stdout=subprocess.DEVNULL)
stub = out/'syntax/Stubs'
env = dict(os.environ, TMPDIR=str(out/'syntax/tmp'), CLANG_MODULE_CACHE_PATH=str(out/'syntax/ModuleCache'))
for sanitized in (False, True):
    executable = out/('protocol-sanitized' if sanitized else 'protocol')
    cmd = ['clang', '-std=c11', '-O1' if sanitized else '-O2', '-Wall', '-Wextra', '-Werror',
           '-include', str(stub/'sdk_stubs.h'), '-I'+str(stub), '-DPICO_RP2040=1',
           '-DFDS_ENABLE_FIXTURE=0', str(root/'tests/test_signal_bench.c'), str(root/'pulse_estimator.c'), '-lm', '-o', str(executable)]
    if sanitized:
        cmd.extend(['-fsanitize=address,undefined', '-fno-omit-frame-pointer'])
    subprocess.run(cmd, check=True, env=env)
    result=subprocess.run([str(executable)], check=True, capture_output=True, text=True, env=env)
    lines=result.stdout.splitlines()
    assert sum(line.startswith('SB1 HELLO ') for line in lines)==12, 'Resync probes must return HELLO, even after malformed commands or ADC restoration faults'
    assert all(' firmware=1.5 ' in line and ' stage_diag=1 ' in line and line.endswith(' cal_series=1 observe=1') for line in lines if line.startswith('SB1 HELLO '))
    assert 'SB1 MANUAL state=active lease_ms=5000' in lines
    assert any(' adc=1234 adc_error=0 ' in line for line in lines if line.startswith('SB1 LIVE '))
    assert lines.count('SB1 ERROR MANUAL_ADC_RELEASED')==5
    assert lines.count('SB1 ERROR MANUAL_TIMER_UNAVAILABLE')==1
    stages=[line for line in lines if line.startswith('SB1 STAGES ')]
    assert len(stages)==5
    for line,seq in zip(stages,[1,2,3,4,4294967295]):
        assert len(line)<384
        fields=dict(piece.split('=') for piece in line.split()[2:])
        assert set(fields)=={'seq',*(f'{prefix}{channel}{suffix}' for channel in range(3) for prefix,suffix in [('adc',''),('err',''),('t','_us')])}
        assert int(fields['seq'])==seq
        assert 0<int(fields['t0_us'])<int(fields['t1_us'])<int(fields['t2_us'])
        for channel in range(3):
            expected_error=(seq==2 and channel==1) or (seq==3 and channel==2) or (seq==4 and channel==0)
            assert fields[f'err{channel}']==str(int(expected_error))
            assert fields[f'adc{channel}']==('-' if expected_error else str(2000+channel*100))
    for error in ['BAD_SEQUENCE','DIAG_INACTIVE','DIAG_ACTIVE','ADC_RESTORE','ADC_RESTORE_REQUIRED']:
        assert f'SB1 ERROR {error}' in lines
    transfers=[]; current=[]
    for line in lines:
        if line.startswith('SB1 BEGIN '): current=[line]
        elif current:
            current.append(line)
            if line.startswith('SB1 END '): transfers.append(current);current=[]
    assert len(transfers)==2
    for transfer, expected in zip(transfers,(32768,0)):
        metadata=''.join(x+'\n' for x in transfer if x.startswith('SB1 BEGIN ') or x.startswith('SB1 EVENT '))
        chunks=[x.split(' ',4) for x in transfer if x.startswith('SB1 DATA ')]
        assert len(chunks)==expected//128 and all(int(x[3])==i*128 for i,x in enumerate(chunks))
        raw=b''.join(bytes.fromhex(x[4]) for x in chunks)
        assert len(raw)==expected*2
        if expected:
            assert raw[:2] == bytes.fromhex('2381')
            assert raw[254:258] == bytes.fromhex('ff0fab00')
            assert raw[-2:] == bytes.fromhex('0180')
        meta_crc=next(x.split()[-1] for x in transfer if x.startswith('SB1 META '))
        end=next(x.split() for x in transfer if x.startswith('SB1 END '))
        assert int(end[-2])==expected
        assert format(zlib.crc32(metadata.encode()),'08x')==meta_crc
        assert format(zlib.crc32(raw),'08x')==end[-1]
    assert 'PASS: Signal Bench protocol' in result.stdout
    print(('sanitized' if sanitized else 'optimized')+': PASS fake SDK protocol and independent wire CRC checks')
