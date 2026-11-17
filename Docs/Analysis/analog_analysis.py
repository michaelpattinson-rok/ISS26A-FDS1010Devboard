#!/usr/bin/env python3
"""Rev E analysis correction. NumPy only; all artifacts stay beside this file.

Linear transfer-function calculations, NOT measurements or qualification.
Preserves the populated 27-part circuit. No CAD, BOM, firmware, release, or
external application is written. Run with the bundled Python/NumPy runtime.

The exact exponential pulse method is deliberately independent of the copied
review script's sampled, recursive low-pass implementation. Both are retained.
"""
from __future__ import annotations

import csv
import hashlib
import itertools
import json
import math
from dataclasses import dataclass, replace
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
KB = 1.380649e-23
QE = 1.602176634e-19
TEMP_K = 300.0
VMID = 1.65
STOP_S = 0.030


@dataclass(frozen=True)
class Circuit:
    rf: float = 100e6
    cf: float = 10e-12
    cd: float = 1e-9
    cp: float = 6e-12
    fu: float = 10e6
    r4: float = 10e3
    r5: float = 1e6
    c5: float = 10e-9
    r6: float = 52.3e3
    rg: float = 1e3
    c6: float = 100e-12
    r9: float = 10e3
    r10: float = 49.9e3
    c7: float = 10e-9
    r11: float = 1e3
    c8: float = 1e-9

    @property
    def gain(self):
        return 1 + self.r6 / self.rg


def write_csv(name, rows):
    with (HERE / name).open('w', newline='') as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def noise_gain(f, p):
    s = 2j * np.pi * np.asarray(f)
    return (1 + s * p.rf * (p.cd + p.cp + p.cf)) / (1 + s * p.rf * p.cf)


def open_loop(f, fu, mode='corrected_Hz'):
    """All f, fu, f2 in Hz. No mixing f with angular frequency.

    In corrected_Hz, fu is the dominant gain-bandwidth scale, rather than
    exactly the unity crossing of the two-pole response. f2=fu/tan(25deg).
    calibrated_65deg instead normalizes |A(fu)|=1, phase=-115deg exactly.
    This is a convenient parameterization, not a fitted vendor macro-model.
    """
    f2 = fu / math.tan(math.radians(25.0))
    scale = 1 / math.cos(math.radians(25.0)) if mode == 'calibrated_65deg' else 1.0
    return scale * fu / (1j * np.asarray(f)) / (1 + 1j * np.asarray(f) / f2)


def loop_metrics(p, mode='corrected_Hz'):
    lo, hi = 0.01, 4 * p.fu
    assert abs(open_loop(lo, p.fu, mode) / noise_gain(lo, p)) > 1
    assert abs(open_loop(hi, p.fu, mode) / noise_gain(hi, p)) < 1
    for _ in range(75):
        mid = math.sqrt(lo * hi)
        if abs(open_loop(mid, p.fu, mode) / noise_gain(mid, p)) > 1:
            lo = mid
        else:
            hi = mid
    fc = math.sqrt(lo * hi)
    pm = 180 + float(np.angle(open_loop(fc, p.fu, mode) / noise_gain(fc, p), deg=True))
    return fc, pm


def loop_scan():
    rows = []
    for cd, rf_s, cf_s, fu, cp in itertools.product(
            (0.4e-9, 1e-9, 5e-9), (.99, 1., 1.01), (.95, 1., 1.05),
            (8e6, 10e6, 12e6), (0., 6e-12, 20e-12)):
        p = Circuit(cd=cd, rf=100e6*rf_s, cf=10e-12*cf_s, fu=fu, cp=cp)
        fc, pm = loop_metrics(p)
        fc_cal, pm_cal = loop_metrics(p, 'calibrated_65deg')
        rows.append(dict(Cdet_nF=cd*1e9, Cpar_pF=cp*1e12, Rf_ohm=p.rf,
            Cf_pF=p.cf*1e12, GBW_scale_MHz=fu/1e6,
            NG_rise_start_Hz=1/(2*math.pi*p.rf*(cd+cp+p.cf)),
            NG_plateau_start_Hz=1/(2*math.pi*p.rf*p.cf),
            NG_plateau=1+(cd+cp)/p.cf,
            extra_open_loop_pole_Hz=fu/math.tan(math.radians(25)),
            crossover_corrected_Hz=fc, phase_margin_corrected_deg=pm,
            crossover_calibrated_65deg_Hz=fc_cal,
            phase_margin_calibrated_65deg_deg=pm_cal))
    assert len(rows) == 243
    write_csv('tia_loop_scan.csv', rows)
    return rows


@dataclass(frozen=True)
class Terms:
    """H(s)=constant * product(s-zero) / product(s-pole), SI units."""
    constant: float
    poles: tuple
    zeros: tuple = ()

    def then(self, constant=1., poles=(), zeros=()):
        return Terms(self.constant*constant, self.poles+tuple(poles), self.zeros+tuple(zeros))

    def residues(self):
        result = []
        for index, pole in enumerate(self.poles):
            numerator = self.constant
            denominator = 1.
            for zero in self.zeros:
                numerator *= pole-zero
            for other_index, other_pole in enumerate(self.poles):
                if other_index != index:
                    denominator *= pole-other_pole
            if denominator == 0:
                raise ValueError('Coincident poles require a repeated-pole solver')
            result.append(numerator/denominator)
        return np.asarray(result, dtype=complex)

    def at_s(self, s):
        answer = complex(self.constant)
        for zero in self.zeros:
            answer *= s-zero
        for pole in self.poles:
            answer /= s-pole
        return answer


def chain_terms(p, csa_mode='two_pole', legacy_post=False):
    """Finite CSA with ideal VMID and ideal downstream amplifiers.

    For finite A(s), Z_CSA = -A / [s(Cd+Cp)+(1+A)(1/Rf+s Cf)].
    With A=K*w2/[s(s+w2)], the CSA denominator is cubic. Exact
    poles/residues avoid a time-step approximation. Real circuit output
    impedances, finite DC gain, coupled VMID paths and nonlinearities omitted.
    """
    ct = p.cd+p.cp+p.cf
    conductance = 1/p.rf
    k = 2*math.pi*p.fu
    w2 = 2*math.pi*p.fu/math.tan(math.radians(25))
    if csa_mode == 'two_pole':
        poles = np.roots([ct, conductance+w2*ct,
                         w2*conductance+k*w2*p.cf, k*w2*conductance])
        csa = Terms(-k*w2/ct, tuple(poles))
    elif csa_mode == 'dominant_pole':
        poles = np.roots([ct, conductance+k*p.cf, k*conductance])
        csa = Terms(-k/ct, tuple(poles))
    elif csa_mode == 'ideal':
        csa = Terms(-1/p.cf, (-1/(p.rf*p.cf),))
    else:
        raise ValueError(csa_mode)
    assert all(np.real(x) < 0 for x in csa.poles)
    hp_tau = (p.r4+p.r5)*p.c5
    attenuation = p.r5/(p.r4+p.r5)
    if legacy_post:
        hp_tau = p.r5*p.c5
        attenuation = 1.
    hp = csa.then(attenuation, (-1/hp_tau,), (0.,))
    gain = hp.then(p.gain) if legacy_post else hp.then(
        poles=(-1/(p.r6*p.c6),), zeros=(-p.gain/(p.r6*p.c6),))
    shaped = gain.then(-1/(p.r9*p.c7), (-1/(p.r10*p.c7),))
    adc = shaped.then(1/(p.r11*p.c8), (-1/(p.r11*p.c8),))
    return dict(CSA_RAW=csa, GAIN_RAW=gain, SHAPED_RAW=shaped, ADC_OUT=adc)


def response(terms, t, charge_fc=22., collection_us=0.):
    t = np.atleast_1d(np.asarray(t, dtype=float))
    poles = np.asarray(terms.poles, dtype=complex)[:, None]
    residues = terms.residues()[:, None]
    width = collection_us*1e-6
    if width == 0:
        answer = np.sum(residues*np.exp(poles*t), axis=0)
    else:
        # Convolve the impulse response with a rectangular current Q/width.
        active = np.minimum(t, width)
        after = np.maximum(0., t-width)
        integrated = np.exp(poles*after)*np.expm1(poles*active)/poles
        answer = np.sum(residues*integrated, axis=0)/width
    assert np.max(np.abs(np.imag(answer))) < max(1., np.max(np.abs(answer)))*1e-7
    return np.real(answer)*charge_fc*1e-15


def refined_extrema(terms, charge_fc, collection_us):
    grid = np.r_[0., np.geomspace(1e-10, STOP_S, 900)]
    if collection_us:
        width = collection_us*1e-6
        grid = np.unique(np.r_[grid, width, width+np.geomspace(1e-9, STOP_S-width, 300)])
    values = response(terms, grid, charge_fc, collection_us)
    result = []
    for sign in (1., -1.):
        index = int(np.argmax(sign*values))
        best_t, best_v = float(grid[index]), float(values[index])
        if 0 < index < len(grid)-1:
            left, right = float(grid[index-1]), float(grid[index+1])
            ratio = (math.sqrt(5)-1)/2
            c, d = right-ratio*(right-left), left+ratio*(right-left)
            def evaluate(time):
                return sign*float(response(terms, [time], charge_fc, collection_us)[0])
            fc, fd = evaluate(c), evaluate(d)
            for _ in range(35):
                if fc > fd:
                    right, d, fd = d, c, fc
                    c = right-ratio*(right-left); fc = evaluate(c)
                else:
                    left, c, fc = c, d, fd
                    d = left+ratio*(right-left); fd = evaluate(d)
            time = (left+right)/2
            value = float(response(terms, [time], charge_fc, collection_us)[0])
            if sign*value > sign*best_v:
                best_t, best_v = time, value
        result.append((best_t, best_v))
    return result  # maximum, minimum; within the explicit 30 ms window


def pulse_row(p, gain_name, charge=22., width=0., csa_mode='two_pole', legacy_post=False):
    row = dict(gain=gain_name, gain_DC=p.gain, Cdet_nF=p.cd*1e9,
               charge_fC=charge, collection_us=width)
    terms = chain_terms(p, csa_mode, legacy_post)
    for name, item in terms.items():
        maximum, minimum = refined_extrema(item, charge, width)
        row[name+'_min_V'] = VMID+minimum[1]
        row[name+'_max_V'] = VMID+maximum[1]
        row[name+'_max_abs_deviation_mV'] = 1e3*max(abs(maximum[1]), abs(minimum[1]))
        row[name+'_linear_0p1_to_3p2V_exceeded'] = VMID+minimum[1] < .1 or VMID+maximum[1] > 3.2
        if name == 'ADC_OUT':
            row['ADC_peak_mV'] = maximum[1]*1e3
            row['ADC_peak_us'] = maximum[0]*1e6
            row['ADC_negative_tail_mV'] = minimum[1]*1e3
    return row


def pulses():
    rows = []
    headroom = []
    for cd, (gain_name, rg), width in itertools.product(
            (.4e-9, 1e-9, 5e-9), (('LOW', 2e3), ('HIGH', 1e3)),
            (0., 1., 10., 100., 500., 1000., 5000.)):
        rows.append(pulse_row(Circuit(cd=cd, rg=rg), gain_name, width=width))
    for (name, rg), charge in itertools.product((('LOW', 2e3), ('HIGH', 1e3)),
                                               (.22, 2.2, 22., 29.45, 100., 250., 500.)):
        headroom.append(pulse_row(Circuit(rg=rg), name, charge))
    write_csv('finite_bandwidth_charge_pulses.csv', rows)
    write_csv('pulse_headroom.csv', headroom)
    waveform = []
    times = np.arange(0., STOP_S+1e-9, 5e-6)
    high = chain_terms(Circuit())
    samples = {key: response(value, times) for key, value in high.items()}
    for index, time in enumerate(times):
        waveform.append(dict(time_us=time*1e6, **{
            key+'_V': VMID+float(value[index]) for key, value in samples.items()}))
    write_csv('nominal_22fC_HIGH_waveform_5us.csv', waveform)
    return rows, headroom


def tolerances():
    # A selected 64-corner study for each gain, comparable to the audit.
    # LOW rg scales R7+R8 together; HIGH rg is R7, R8 shunted. Not an
    # exhaustive all-part tolerance bound and not a statistical yield model.
    rows = []
    for name, rg in (('LOW', 2e3), ('HIGH', 1e3)):
        nominal = Circuit(rg=rg)
        for cf, r6, rg_s, r9, r10, c7 in itertools.product(
                (.95, 1.05), (.99, 1.01), (.99, 1.01), (.99, 1.01), (.99, 1.01), (.95, 1.05)):
            p = replace(nominal, cf=nominal.cf*cf, r6=nominal.r6*r6,
                        rg=nominal.rg*rg_s, r9=nominal.r9*r9,
                        r10=nominal.r10*r10, c7=nominal.c7*c7)
            maximum, minimum = refined_extrema(chain_terms(p)['ADC_OUT'], 22., 0.)
            rows.append(dict(gain=name, cf_scale=cf, r6_scale=r6, rg_scale=rg_s,
                r9_scale=r9, r10_scale=r10, c7_scale=c7,
                ADC_peak_mV=maximum[1]*1e3, ADC_peak_us=maximum[0]*1e6,
                ADC_negative_tail_mV=minimum[1]*1e3))
    write_csv('uncalibrated_tolerance_corners.csv', rows)
    sensitivity = []
    for name, rg in (('LOW', 2e3), ('HIGH', 1e3)):
        nominal = Circuit(rg=rg)
        for key in ('rf','cf','r4','r5','c5','r6','rg','c6','r9','r10','c7','r11','c8'):
            tolerance = .05 if key.startswith('c') else .01
            for scale in (1-tolerance, 1+tolerance):
                p = replace(nominal, **{key:getattr(nominal,key)*scale})
                maximum, _ = refined_extrema(chain_terms(p)['ADC_OUT'], 22., 0.)
                sensitivity.append(dict(gain=name, element=key, scale=scale,
                    ADC_peak_mV=maximum[1]*1e3, ADC_peak_us=maximum[0]*1e6))
    write_csv('one_at_a_time_passive_sensitivity.csv', sensitivity)
    return rows


def partial_noise():
    """Independent uncorrelated-source illustrative PSD, not total noise.

    Typical data-sheet density points are extrapolated as white. No 1/f
    spectrum, VMID correlated network, ADC or sampled alias model is inferred.
    """
    f = np.geomspace(.1, 100e3, 30000)
    s = 2j*np.pi*f
    en, in_op, assumed_leakage = 8.7e-9, 3e-15, 1e-12
    rows = []
    for cd, (name, rg) in itertools.product((.4e-9,1e-9,5e-9), (('LOW',2e3),('HIGH',1e3))):
        p = Circuit(cd=cd, rg=rg)
        a = open_loop(f,p.fu)
        ng = noise_gain(f,p)
        zf = p.rf/(1+s*p.rf*p.cf)
        zcsa = -zf*a/(a+ng)
        en_csa_gain = a*ng/(a+ng)
        hp = p.r5*p.c5*s/(1+(p.r4+p.r5)*p.c5*s)
        z6 = p.r6/(1+s*p.r6*p.c6)
        hg = 1+z6/p.rg
        zs = p.r10/(1+s*p.r10*p.c7)
        hs = -zs/p.r9
        ha = 1/(1+s*p.r11*p.c8)
        downstream = hp*hg*hs*ha
        zpassive = 1/(1/p.r5+1/(p.r4+1/(s*p.c5)))
        psd = {
            'CSA_voltage_noise': en**2*np.abs(en_csa_gain*downstream)**2,
            'CSA_input_current_noise': in_op**2*np.abs(zcsa*downstream)**2,
            'Rf_thermal_noise': 4*KB*TEMP_K/p.rf*np.abs(zcsa*downstream)**2,
            'assumed_1pA_detector_shot_noise': 2*QE*assumed_leakage*np.abs(zcsa*downstream)**2,
            'R4_R5_thermal_noise': 4*KB*TEMP_K*np.real(zpassive)*np.abs(hg*hs*ha)**2,
            'gain_amplifier_voltage_noise': en**2*np.abs(hg*hs*ha)**2,
            'gain_amplifier_input_current_noise': in_op**2*(np.abs(z6*hs*ha)**2+np.abs(zpassive*hg*hs*ha)**2),
            'R6_Rg_thermal_noise': (4*KB*TEMP_K*np.real(z6)+4*KB*TEMP_K/p.rg*np.abs(z6)**2)*np.abs(hs*ha)**2,
            'shape_amplifier_voltage_noise': en**2*np.abs((1+zs/p.r9)*ha)**2,
            'shape_amplifier_inverting_current_noise': in_op**2*np.abs(zs*ha)**2,
            'R9_R10_thermal_noise': 4*KB*TEMP_K*(1/p.r9+1/p.r10)*np.abs(zs*ha)**2,
            'R11_thermal_noise': 4*KB*TEMP_K*p.r11*np.abs(ha)**2,
        }
        variances = {key: float(np.trapezoid(value,f)) for key,value in psd.items()}
        rows.append(dict(Cdet_nF=cd*1e9, gain=name,
            **{key+'_rms_uV':math.sqrt(value)*1e6 for key,value in variances.items()},
            independent_source_partial_subtotal_rms_uV=math.sqrt(sum(variances.values()))*1e6,
            band_low_Hz=.1, band_high_Hz=100e3, assumed_detector_leakage_pA=1.,
            voltage_noise_white_nV_sqrtHz=8.7, current_noise_white_fA_sqrtHz=3.))
    write_csv('partial_noise.csv',rows)
    return rows


def static_bounds():
    rows = []
    for name, current in (('IB_25C_typical',1e-12),('IB_85C_industrial_max',150e-12),
                          ('IB_125C_extended_max',5e-9),('external_1nA',1e-9),
                          ('external_10nA',10e-9),('external_15nA',15e-9)):
        rows.append(dict(case=name,current_A=current,CSA_offset_V_ideal=current*100e6,
            exceeds_selected_1p45V_one_side_budget=current*100e6>1.45))
    write_csv('static_offset_bounds.csv',rows)


def model_checks():
    # A second expression in s checks pole/residue transfer algebra directly.
    p = Circuit()
    chain = chain_terms(p)
    worst = 0.
    for freq in (1.,15.8,159.15,318.95,1e3,1e4,1e5,1e6):
        s = 2j*math.pi*freq
        a = complex(open_loop(freq,p.fu))
        direct = -a/(s*(p.cd+p.cp)+(1+a)*(1/p.rf+s*p.cf))
        direct *= p.r5*p.c5*s/(1+(p.r4+p.r5)*p.c5*s)
        direct *= 1+(p.r6/p.rg)/(1+s*p.r6*p.c6)
        direct *= -(p.r10/p.r9)/(1+s*p.r10*p.c7)
        direct /= 1+s*p.r11*p.c8
        relative = abs(chain['ADC_OUT'].at_s(s)/direct-1)
        worst = max(worst,relative)
    assert worst < 1e-9
    # This normalization is the useful exact check at the quoted unity point.
    a = open_loop(10e6,10e6,'calibrated_65deg')
    assert abs(abs(a)-1) < 1e-12
    assert abs(180+float(np.angle(a,deg=True))-65) < 1e-10
    full = pulse_row(p,'HIGH')
    dom = pulse_row(p,'HIGH',csa_mode='dominant_pole')
    ideal = pulse_row(p,'HIGH',csa_mode='ideal',legacy_post=True)
    # Independent audit method: sampled recursive first-order filters.
    independent_file = HERE/'Independent Validation'/'independent_results.json'
    independent = json.loads(independent_file.read_text()) if independent_file.exists() else None
    reference = independent['full_nominal']['ADC_peak_mV'] if independent else None
    error = 100*(dom['ADC_peak_mV']/reference-1) if reference else None
    if error is not None:
        assert abs(error) < .02
    independent_loop = HERE/'Independent Validation'/'corrected_loop_units.csv'
    loop_pm_error = 0.
    loop_fc_error = 0.
    if independent_loop.exists():
        with independent_loop.open(newline='') as stream:
            for row in csv.DictReader(stream):
                if row['mode'] != 'corrected_Hz':
                    continue
                fc, pm = loop_metrics(replace(p,cd=float(row['Cdet_nF'])*1e-9))
                loop_pm_error = max(loop_pm_error,abs(pm-float(row['modeled_phase_margin_deg'])))
                loop_fc_error = max(loop_fc_error,abs(fc/float(row['crossover_Hz'])-1))
        assert loop_pm_error < 1e-9 and loop_fc_error < 1e-9
    return dict(transfer_algebra_max_relative_error=worst,
        full_two_pole_nominal=full, dominant_pole_nominal=dom,
        legacy_ideal_nominal=ideal, independent_recursive_peak_mV=reference,
        dominant_exact_vs_independent_recursive_percent=error,
        independent_loop_phase_max_abs_error_deg=loop_pm_error,
        independent_loop_crossover_max_relative_error=loop_fc_error,
        independent_recursive_legacy_peak_mV=independent['ideal_previous_assumptions']['ADC_peak_mV'] if independent else None,
        two_pole_vs_dominant_peak_percent=100*(full['ADC_peak_mV']/dom['ADC_peak_mV']-1),
        full_vs_legacy_ideal_peak_percent=100*(full['ADC_peak_mV']/ideal['ADC_peak_mV']-1))


def create_report(loop,pulse,corners,noise,checks):
    nominal = [row for row in loop if row['Rf_ohm']==100e6 and row['Cf_pF']==10 and
               row['GBW_scale_MHz']==10 and row['Cpar_pF']==6]
    nominal_pulse = [row for row in pulse if row['Cdet_nF']==1 and row['collection_us']==0]
    summary = dict(date='2026-10-27', status='Analytical prototype model; not measured or qualified',
        hardware_values_changed=False, component_count_preserved=27,
        loop_combinations=len(loop),
        corrected_phase_margin_range_deg=[min(r['phase_margin_corrected_deg'] for r in loop),max(r['phase_margin_corrected_deg'] for r in loop)],
        calibrated_phase_margin_range_deg=[min(r['phase_margin_calibrated_65deg_deg'] for r in loop),max(r['phase_margin_calibrated_65deg_deg'] for r in loop)],
        nominal_loop_rows=nominal, numerical_checks=checks, tolerance_groups={})
    for name in ('LOW','HIGH'):
        group = [r for r in corners if r['gain']==name]
        nominal_peak = next(r['ADC_peak_mV'] for r in nominal_pulse if r['gain']==name)
        limits = [min(r['ADC_peak_mV'] for r in group),max(r['ADC_peak_mV'] for r in group)]
        summary['tolerance_groups'][name] = dict(corners=len(group),nominal_peak_mV=nominal_peak,
            selected_corner_peak_range_mV=limits,
            selected_corner_percent_from_nominal=[100*(x/nominal_peak-1) for x in limits])
    (HERE/'analysis_results.json').write_text(json.dumps(summary,indent=2)+'\n')
    report = '''# Rev E corrected analog calculations

2026-10-27. These are reproducible linear-model calculations, not hardware measurements, vendor SPICE, release signoff, radiation sensitivity, or a V5 accuracy guarantee. No circuit value or component was changed: 27 THT parts, R3=100 MΩ, C4=10 pF, LOW/HIGH gain 27.15/53.3, R10/C7 shaper −4.99 and 499 µs, R11/C8 output RC 1 µs. The parent implementation separately addresses C2 placement.

## Corrected frequency units and stability scope

`open_loop()` now uses Hz consistently: `A(f)=(fu/(j f))/(1+j f/f2)`, `f2=fu/tan(25°)`. The earlier mixed `j*f/(2*pi*f2)` put the intended 21.445 MHz extra pole at 134.743 MHz. In this corrected parameterization, `fu` is the dominant gain-bandwidth scale; it is not exactly the two-pole unity crossing. A second scan normalizes unity gain at `fu` and 65° phase margin exactly. Neither is a vendor-fitted open-loop response.

`tia_loop_scan.csv` contains 243 combinations of Cdet 0.4/1/5 nF, R3 ±1%, C4 ±5%, gain-bandwidth scale 8/10/12 MHz and local input Cpar 0/6/20 pF. Nominal R3/C4/10 MHz/6 pF cases:

| Cdet nF | crossover Hz, corrected | phase margin °, corrected | phase margin °, normalized |
|---:|---:|---:|---:|
'''
    for row in nominal:
        report += f"| {row['Cdet_nF']:.1f} | {row['crossover_corrected_Hz']:.1f} | {row['phase_margin_corrected_deg']:.3f} | {row['phase_margin_calibrated_65deg_deg']:.3f} |\n"
    lo,hi=summary['corrected_phase_margin_range_deg']
    report += f'''
The corrected scan range is {lo:.3f}–{hi:.3f}°. This simplified model finds no instability in those selected cases; it does not establish actual board stability. Sensor capacitance cases are assumptions, not measurements of the supplied FDS1010 near zero bias. Shared VMID dynamics, real open-loop poles/zeros, output loading, pigtails, loss and inductance, mutual coupling and PCB parasitics are absent. Retain C4=10 pF pending bench or vendor-macro-model verification.

## Actual populated transfer and pulse predictions

With `s` in rad/s, input current-to-CSA transfer is `−A/[s(Cdet+Cpar)+(1+A)(1/R3+s*C4)]`. The pulse solver uses the corrected two-pole A and solves this cubic exactly. It then applies the populated networks:

- R4/C5/R5 coupling: `R5*C5*s/[1+(R4+R5)*C5*s]`; high-frequency attenuation 0.990099, time constant 10.1 ms.
- Non-inverting R6||C6 gain: `1+(R6/Rg)/(1+s*R6*C6)`, Rg=R7+R8 LOW or R7 HIGH. This has a 30.43 kHz pole and a gain-dependent zero, and tends to unity at high frequency. Replacing it with a simple gain low-pass would be wrong.
- Shaper: `−(R10/R9)/(1+s*R10*C7)`, corner 318.95 Hz. Output RC: `1/(1+s*R11*C8)`.

Downstream amplifiers are ideal in the pulse solver. VMID is an ideal common reference. Finite DC gain, input/output impedance, slew limiting, clamps, saturation/recovery and the host ADC are omitted. Exact pole/residue exponentials avoid a time-step approximation; a 30 ms window is stated for extrema. Rectangular equal-charge collection tests convolve the exact impulse response with current Q/width.

| 22 fC, assumed 1 nF | ADC positive peak mV | peak time µs |
|---|---:|---:|
'''
    for row in nominal_pulse:
        report += f"| {row['gain']} | {row['ADC_peak_mV']:.3f} | {row['ADC_peak_us']:.2f} |\n"
    report += f'''
For HIGH, the exact legacy ideal transfer gives {checks['legacy_ideal_nominal']['ADC_peak_mV']:.3f} mV; the full calculation changes it by {checks['full_vs_legacy_ideal_peak_percent']:.3f}%. The copied audit's sampled ideal implementation gives {checks['independent_recursive_legacy_peak_mV']:.3f} mV; its initial discontinuity/time-step treatment explains that small difference. The independent copied audit solver uses a dominant-pole CSA and recursive sampled filters. Its full nominal peak is {checks['independent_recursive_peak_mV']:.3f} mV; our exact dominant-pole calculation differs by {checks['dominant_exact_vs_independent_recursive_percent']:.5f}%. Adding the extra CSA pole changes the peak by {checks['two_pole_vs_dominant_peak_percent']:.5f}%. Transfer algebra was also cross-checked at eight frequencies (maximum relative residual {checks['transfer_algebra_max_relative_error']:.2g}); the nominal loop values agree with the independent scalar unit check to numerical precision.

Equal-charge HIGH 22 fC collection examples, relative to its impulse:

| Collection width µs | peak mV | change % |
|---:|---:|---:|
'''
    baseline=next(r['ADC_peak_mV'] for r in nominal_pulse if r['gain']=='HIGH')
    for row in pulse:
        if row['gain']=='HIGH' and row['Cdet_nF']==1 and row['collection_us'] in (100,500,1000,5000):
            report += f"| {row['collection_us']:.0f} | {row['ADC_peak_mV']:.3f} | {100*(row['ADC_peak_mV']/baseline-1):.3f} |\n"
    report += '''
These widths are test inputs, not measured collection-time distributions. Fast isolated-pulse calibration can map a filtered peak to collected charge. Filtering and calibration do not recover arbitrary original waveforms or charge hidden by noise. The 319 Hz shaper therefore does not establish V5 waveform fidelity or accuracy.

## Uncalibrated tolerance and headroom

`uncalibrated_tolerance_corners.csv` contains 64 selected independent corners per gain: C4/C7 ±5%, R6/Rg/R9/R10 ±1%. LOW treats R7 and R8 as moving together; HIGH bypasses R8. All other values remain nominal for this study. `one_at_a_time_passive_sensitivity.csv` separately varies all 13 modeled passive parameters, including R4/R5/C5/C6/R11/C8 and R3. Neither file is an exhaustive guaranteed tolerance bound; ADC/reference errors, fixture uncertainty, temperature, leakage, resistor excess noise and feedback stray capacitance are excluded.

| Gain | nominal mV | selected corner range mV | change from nominal % |
|---|---:|---:|---:|
'''
    for name,row in summary['tolerance_groups'].items():
        limits=row['selected_corner_peak_range_mV']; percent=row['selected_corner_percent_from_nominal']
        report += f"| {name} | {row['nominal_peak_mV']:.3f} | {limits[0]:.3f}–{limits[1]:.3f} | {percent[0]:.2f} to +{percent[1]:.2f} |\n"
    report += '''
`pulse_headroom.csv` checks CSA_RAW, GAIN_RAW, SHAPED_RAW and ADC_OUT separately for 0.22–500 fC impulses at assumed 1 nF. A selected 0.1–3.2 V window is only a linear-model diagnostic, not guaranteed loaded output swing. ADC maximum alone cannot establish upstream linearity. Offsets and leakage reduce usable headroom; final-stage AC coupling can conceal a saturated CSA. At R3=100 MΩ, external 1 nA gives approximately 0.1 V DC CSA shift, 10 nA gives 1 V, and 15 nA gives 1.5 V while the loop remains linear. The separate 1.45 V budget is a deliberately smaller selected margin, not the CSV window's exact half-span.

## Noise: illustrative partial subtotal only

`partial_noise.csv` uses the finite CSA and actual downstream ideal transfer functions over 0.1 Hz–100 kHz. It includes separate CSA and downstream amplifier voltage/current noise terms, R3/R4/R5/R6/Rg/R9/R10/R11 thermal noise at 300 K, and an explicitly assumed 1 pA detector shot-noise case. Densities are extrapolated as white; that extrapolation is an assumption. The source contributions are independent in this simplified model.

| Cdet nF | LOW partial RMS µV | HIGH partial RMS µV |
|---:|---:|---:|
'''
    for cd in (.4,1.,5.):
        vals=[next(r['independent_source_partial_subtotal_rms_uV'] for r in noise if abs(r['Cdet_nF']-cd)<1e-8 and r['gain']==g) for g in ('LOW','HIGH')]
        report += f'| {cd:.1f} | {vals[0]:.2f} | {vals[1]:.2f} |\n'
    report += '''
These subtotals are neither measured system RMS nor strict lower bounds. Missing terms include full frequency-dependent amplifier spectra and finite downstream responses, real detector noise, excess resistor noise, board leakage/pickup, source/charge statistics, clamp leakage/capacitance, host supply/radio coupling, temperature, ADC/reference/quantization/sampling and aliasing, and correlated VMID/reference paths. The previous independent VMID quadrature approximation has been removed: a shared reference has correlated cancellation and injection paths requiring a complete model or measurement. No SNR, threshold, energy accuracy, or complete Rev E/V5 noise ratio is inferred.

## Layout and commissioning consequences

Keep the close C2-to-U1.4 bypass connection and short ground-plane return addressed by the parent layout. Retain the existing local ground-copper void beneath SUM and its guarded high-impedance routing; adding grounded copper there would add capacitance to a sensitive node. Keep SUM and feedback paths short, clean and dry; separate the host/digital wiring and use short detector leads. Geometry recommendations do not substitute for measured supply impedance or parasitic extraction.

After assembly, record 3V3, VMID and every raw-stage baseline, darkness leakage and drift. Test high-frequency ringing/oscillation with dummy capacitance and real sensor/pigtails. Inject several independently measured charges and collection widths in both gains; measure linearity, tails, clipping/recovery, ADC reference and sample settling under host workloads. Electrical injection validates the electronics; source/background experiments and detector collection require their own evidence.

## Sources and reproduction

- [Microchip MCP602x DS20001685E](https://ww1.microchip.com/downloads/en/DeviceDoc/20001685E.pdf), AC table p.4: typical 10 MHz, 65° unity-gain phase margin, 8.7 nV/√Hz at 10 kHz and **3 fA/√Hz at 1 kHz**. The audit's statement that 3 fA was absent from that table was incorrect; it is a typical point specification, not a guaranteed broadband spectrum. Sections 4.7/4.9/4.10 cover bypassing, guarding and layout.
- [Raspberry Pi Pico 2 datasheet](https://datasheets.raspberrypi.com/pico/pico-2-datasheet.pdf): host board and ADC connections. Its nominal resolution does not establish system accuracy.
- Local authoritative topology input: preserved final-audit `Automated/CAD/Circuit.json`; 27-part topology is recorded by SHA-256 in `source_manifest.json`. The copied original implementation and independent audit scripts are retained beside this report; nothing was overwritten.

Run `Independent Validation/independent_transfer.py`, then `analog_analysis.py` with the bundled Python containing NumPy. `Independent Validation/loop_units_crosscheck.py` provides a separate scalar frequency-unit check. `analysis_results.json` contains machine-readable summary values and numerical cross-check residuals. CSVs contain the actual calculations, including the 243-corner loop scan, pulse extrema, sample waveform, selected tolerance corners, passive sensitivity and partial source-noise contributions.
'''
    (HERE/'Analog Analysis.md').write_text(report)
    short = f'''# Rev E analysis correction summary

The analysis was corrected without changing any hardware value, BOM, CAD, or firmware. All results below are calculations for an unqualified prototype, not measurements or a V5 accuracy guarantee.

- Corrected the Hz/rad/s extra-pole defect. The intended 21.445 MHz pole had been implemented at 134.743 MHz. All **243 loop corners** rerun; selected-model phase-margin range **{lo:.3f}–{hi:.3f}°**. This does not qualify the real board's stability.
- Added actual R4/C5/R5 coupling, the **non-inverting R6||C6 zero and pole**, finite two-pole CSA, shaper and output RC. At assumed 1 nF and 22 fC impulse, predicted LOW/HIGH ADC peaks are **141.008/276.822 mV** at approximately 656 µs. The independent recursive pulse model agrees with our exact dominant-pole solution to **{checks['dominant_exact_vs_independent_recursive_percent']:.5f}%**.
- Selected HIGH component corners give **253.855–302.648 mV**, approximately **−8.30/+9.33%** before calibration. This selected six-parameter sweep is not a guaranteed all-error bound. Collection width also matters: a 1 ms equal-charge pulse loses about 9.1% peak; 5 ms loses about 68.1%.
- Added downstream resistor and amplifier sources to the illustrative noise calculation. At assumed 1 nF, partial LOW/HIGH RMS is **3.030/5.948 mV** over 0.1 Hz–100 kHz. The result excludes real detector, correlated VMID, ADC/aliasing, pickup and several other sources, so it establishes no total noise, detection threshold or accuracy.
- Corrected an audit-source detail: Microchip's AC table does list **3 fA/√Hz typical at 1 kHz**. Treating it or 8.7 nV/√Hz as a broadband white spectrum remains a modeling assumption.

Keep the existing C4=10 pF and ground-copper void under SUM. C2's short bypass path is handled by the parent layout. After assembly, verify raw-stage baselines, leakage/drift, high-frequency stability, measured charge/width linearity and ADC/reference behavior before making accuracy claims.

Detailed equations, limitations and primary references: [Analog Analysis.md](Analog%20Analysis.md). Reproducible source: `analog_analysis.py`; machine summary: `analysis_results.json`; numeric evidence: `tia_loop_scan.csv`, `finite_bandwidth_charge_pulses.csv`, `pulse_headroom.csv`, `uncalibrated_tolerance_corners.csv`, `one_at_a_time_passive_sensitivity.csv` and `partial_noise.csv`. Unchanged audit scripts and their rerun outputs are in `Independent Validation/`. Baseline topology/source hashes are in `source_manifest.json`.
'''
    (HERE/'Analysis Summary.md').write_text(short)
    return summary


def main():
    topology=json.loads((HERE/'Source Evidence'/'Circuit.json').read_text())
    assert len(topology['parts']) == topology['component_count'] == 27
    values={part['ref']:part['value'] for part in topology['parts']}
    for ref,value in dict(R3='100M',C4='10p C0G',R4='10k',R5='1M',C5='10n C0G',
                          R6='52.3k',R7='1k',R8='1k',C6='100p C0G',R9='10k',
                          R10='49.9k',C7='10n C0G',R11='1k',C8='1n C0G').items():
        assert values[ref] == value, (ref,values[ref],value)
    loop = loop_scan()
    pulse, _ = pulses()
    corners = tolerances()
    noise = partial_noise()
    static_bounds()
    checks = model_checks()
    summary = create_report(loop,pulse,corners,noise,checks)
    sources = [HERE/'analog_analysis.py', HERE/'Source Evidence'/'Circuit.json',
               HERE/'Independent Validation'/'independent_transfer.py',
               HERE/'Independent Validation'/'loop_units_crosscheck.py']
    manifest = {str(path.relative_to(HERE)): hashlib.sha256(path.read_bytes()).hexdigest()
                for path in sources}
    (HERE/'source_manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
    print(json.dumps(dict(loop_rows=len(loop),pulse_rows=len(pulse),tolerance_rows=len(corners),
        phase_margin_range_deg=summary['corrected_phase_margin_range_deg'],
        independent_peak_check_percent=checks['dominant_exact_vs_independent_recursive_percent'],
        output_directory=str(HERE)),indent=2))


if __name__ == '__main__':
    main()
