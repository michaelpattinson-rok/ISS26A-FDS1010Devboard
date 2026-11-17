#!/usr/bin/env python3
"""Independent frequency-unit regression check, never edits the release."""
import cmath
import csv
import math
from pathlib import Path

HERE=Path(__file__).resolve().parent

def noise_gain(f,cd):
    s=2j*math.pi*f
    return (1+s*100e6*(cd+6e-12+10e-12))/(1+s*100e6*10e-12)

def aol(f,mode):
    fu=10e6
    f2=fu/math.tan(math.radians(25.))
    if mode=='published_Hz_rad_mix':return fu/(1j*f)/(1+1j*f/(2*math.pi*f2))
    if mode=='corrected_Hz':return fu/(1j*f)/(1+1j*f/f2)
    if mode=='calibrated_65deg_at_10MHz':return fu/math.cos(math.radians(25.))/(1j*f)/(1+1j*f/f2)
    raise ValueError(mode)

rows=[]
for cd in (.4e-9,1e-9,5e-9):
    for mode in ('published_Hz_rad_mix','corrected_Hz','calibrated_65deg_at_10MHz'):
        lower,upper=1.,100e6
        for _ in range(100):
            middle=math.sqrt(lower*upper)
            if abs(aol(middle,mode)/noise_gain(middle,cd))>1:lower=middle
            else:upper=middle
        f=math.sqrt(lower*upper)
        rows.append({'Cdet_nF':cd*1e9,'mode':mode,'crossover_Hz':f,
                     'modeled_phase_margin_deg':180+math.degrees(cmath.phase(aol(f,mode)/noise_gain(f,cd)))})
with (HERE/'corrected_loop_units.csv').open('w',newline='') as f:
    w=csv.DictWriter(f,fieldnames=rows[0]);w.writeheader();w.writerows(rows)
for row in rows:print(row)
