#!/usr/bin/env python3
"""Read-only source audit model; all generated results stay beside this file.

Linear nominal analytic model, not vendor SPICE or measured performance.
Includes finite dominant-pole CSA GBW, R4/C5/R5 coupling, C6 feedback,
shaper and ADC RC. No ADC nonidealities, parasitic feedback C, saturation,
noise or detector collection physics are claimed to be represented.
"""
import csv
import itertools
import json
import math
from pathlib import Path

HERE=Path(__file__).resolve().parent

def pulse(cd_nf=1.0, gain=53.3, charge_fc=22.0, collection_us=0.0,
          rf_scale=1., cf_scale=1., r6_scale=1., rg_scale=1.,
          r9_scale=1., r10_scale=1., c7_scale=1., dt=0.25e-6,
          finite_bw=True, full_chain=True):
    rf=100e6*rf_scale; cf=10e-12*cf_scale
    wu=2*math.pi*10e6
    cd=(cd_nf*1e-9)+6e-12
    if finite_bw:
        a2=cd+cf; a1=1/rf+wu*cf; a0=wu/rf
        d=math.sqrt(a1*a1-4*a2*a0)
        slow=2*a0/(a1+d); fast=(a1+d)/(2*a2)
        norm=-wu/(a2*(fast-slow))
    else:
        slow=1/(rf*cf); fast=math.inf; norm=-1/cf
    tau_hp=(1.01e6 if full_chain else 1e6)*10e-9
    attenuation=1e6/1.01e6 if full_chain else 1.
    gain=(1+(gain-1)*r6_scale/rg_scale)
    tau6=52.3e3*r6_scale*100e-12
    tau_shape=49.9e3*r10_scale*10e-9*c7_scale
    shape_gain=4.99*r10_scale/r9_scale
    taus=(tau_hp,tau6,tau_shape,1e-6)
    coeff=[]
    for tau in taus:
        alpha=math.exp(-dt/tau)
        # Exact LP solution for a linear input segment from x0 to x1.
        b0=(1-alpha)-((dt-tau*(1-alpha))/dt)
        b1=(dt-tau*(1-alpha))/dt
        coeff.append((alpha,b0,b1))
    states=[0.,0.,0.,0.]; previous=[0.,0.,0.,0.]
    def update(index,value):
        alpha,b0,b1=coeff[index]
        states[index]=alpha*states[index]+b0*previous[index]+b1*value
        previous[index]=value
        return states[index]
    def exp_integral(rate,t):
        return -math.expm1(-rate*max(0.,t))/rate
    q=charge_fc*1e-15
    duration=collection_us*1e-6
    peak=0.; peak_t=0.; minimum=0.; csa_min=0.; gain_min=0.
    stride=max(1,round(104e-6/dt))
    avr_samples=[]
    sampled=[]
    for i in range(round(30e-3/dt)+1):
        t=i*dt
        if duration:
            window_s=exp_integral(slow,t)-exp_integral(slow,t-duration)
            window_f=0. if not finite_bw else exp_integral(fast,t)-exp_integral(fast,t-duration)
            csa=q/duration*norm*(window_s-window_f)
        else:
            csa=q*norm*(math.exp(-slow*t)-(math.exp(-fast*t) if finite_bw else 0.))
        # The ideal impulse CSA is discontinuous at t=0.
        if i==0 and not finite_bw:
            previous[0]=csa
        hp=attenuation*(csa-update(0,csa))
        gain_raw=hp+(gain-1)*update(1,hp) if full_chain else gain*hp
        shaped=-shape_gain*update(2,gain_raw)
        adc=update(3,shaped)
        if adc>peak: peak=adc; peak_t=t
        minimum=min(minimum,adc)
        csa_min=min(csa_min,csa); gain_min=min(gain_min,gain_raw)
        if i%40==0: sampled.append(adc)
        if i%stride==0: avr_samples.append(adc)
    return {'cd_nF':cd_nf,'gain':gain,'charge_fC':charge_fc,'collection_us':collection_us,
            'ADC_peak_mV':peak*1e3,'peak_us':peak_t*1e6,'negative_tail_mV':minimum*1e3,
            'CSA_peak_mV':-csa_min*1e3,'GAIN_peak_mV':-gain_min*1e3,
            'Pico_zero_phase_sampled_peak_mV':max(sampled)*1e3,
            'AVR_zero_phase_sampled_peak_mV':max(avr_samples)*1e3}

nominal=[]
for cd in (.4,1.,5.):
    for gain in (27.15,53.3):
        for width in (0.,1.,10.,100.,500.,1000.,5000.):
            nominal.append(pulse(cd,gain,collection_us=width))
with (HERE/'finite_bandwidth_charge_pulses.csv').open('w',newline='') as f:
    w=csv.DictWriter(f,fieldnames=nominal[0]); w.writeheader();w.writerows(nominal)

# Extremal tolerances on all relevant gain-shape elements. R5/R4 omitted
# here: their tolerance is much smaller than the listed C0G tolerances.
corners=[]
for cf,r6,rg,r9,r10,c7 in itertools.product((.95,1.05),(.99,1.01),(.99,1.01),(.99,1.01),(.99,1.01),(.95,1.05)):
    row=pulse(1.,53.3,cf_scale=cf,r6_scale=r6,rg_scale=rg,r9_scale=r9,r10_scale=r10,c7_scale=c7,dt=1e-6)
    row.update(cf_scale=cf,r6_scale=r6,rg_scale=rg,r9_scale=r9,r10_scale=r10,c7_scale=c7)
    corners.append(row)
with (HERE/'uncalibrated_tolerance_corners.csv').open('w',newline='') as f:
    w=csv.DictWriter(f,fieldnames=corners[0]);w.writeheader();w.writerows(corners)

ideal=pulse(1.,53.3,finite_bw=False,full_chain=False)
full=pulse(1.,53.3)
nominal_full_peak=full['ADC_peak_mV']
summary={'model':'Linear nominal, dominant-pole opamp, no nonlinear/ADC/noise qualification',
         'ideal_previous_assumptions':ideal,'full_nominal':full,
         'nominal_full_vs_ideal_peak_percent':100*(nominal_full_peak/ideal['ADC_peak_mV']-1),
         'uncalibrated_corners_mV':[min(x['ADC_peak_mV'] for x in corners),max(x['ADC_peak_mV'] for x in corners)],
         'uncalibrated_corners_percent_from_nominal':[100*(min(x['ADC_peak_mV'] for x in corners)/nominal_full_peak-1),100*(max(x['ADC_peak_mV'] for x in corners)/nominal_full_peak-1)],
         'shaper_3dB_Hz':1/(2*math.pi*499e-6),
         'Hz_to_rad_per_sec_model_bug':{'documented_extra_pole_Hz':10e6/math.tan(math.radians(25)),
                                      'implemented_extra_pole_Hz':2*math.pi*10e6/math.tan(math.radians(25))}}
(HERE/'independent_results.json').write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps(summary,indent=2))
