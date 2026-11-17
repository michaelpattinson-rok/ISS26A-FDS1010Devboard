# Rev E corrected analog calculations

2026-10-27. These are reproducible linear-model calculations, not hardware measurements, vendor SPICE, release signoff, radiation sensitivity, or a V5 accuracy guarantee. No circuit value or component was changed: 27 THT parts, R3=100 MΩ, C4=10 pF, LOW/HIGH gain 27.15/53.3, R10/C7 shaper −4.99 and 499 µs, R11/C8 output RC 1 µs. The parent implementation separately addresses C2 placement.

## Corrected frequency units and stability scope

`open_loop()` now uses Hz consistently: `A(f)=(fu/(j f))/(1+j f/f2)`, `f2=fu/tan(25°)`. The earlier mixed `j*f/(2*pi*f2)` put the intended 21.445 MHz extra pole at 134.743 MHz. In this corrected parameterization, `fu` is the dominant gain-bandwidth scale; it is not exactly the two-pole unity crossing. A second scan normalizes unity gain at `fu` and 65° phase margin exactly. Neither is a vendor-fitted open-loop response.

`tia_loop_scan.csv` contains 243 combinations of Cdet 0.4/1/5 nF, R3 ±1%, C4 ±5%, gain-bandwidth scale 8/10/12 MHz and local input Cpar 0/6/20 pF. Nominal R3/C4/10 MHz/6 pF cases:

| Cdet nF | crossover Hz, corrected | phase margin °, corrected | phase margin °, normalized |
|---:|---:|---:|---:|
| 0.4 | 240369.6 | 89.321 | 89.258 |
| 1.0 | 98424.3 | 89.645 | 89.627 |
| 5.0 | 19936.8 | 89.490 | 89.528 |

The corrected scan range is 89.275–89.668°. This simplified model finds no instability in those selected cases; it does not establish actual board stability. Sensor capacitance cases are assumptions, not measurements of the supplied FDS1010 near zero bias. Shared VMID dynamics, real open-loop poles/zeros, output loading, pigtails, loss and inductance, mutual coupling and PCB parasitics are absent. Retain C4=10 pF pending bench or vendor-macro-model verification.

## Actual populated transfer and pulse predictions

With `s` in rad/s, input current-to-CSA transfer is `−A/[s(Cdet+Cpar)+(1+A)(1/R3+s*C4)]`. The pulse solver uses the corrected two-pole A and solves this cubic exactly. It then applies the populated networks:

- R4/C5/R5 coupling: `R5*C5*s/[1+(R4+R5)*C5*s]`; high-frequency attenuation 0.990099, time constant 10.1 ms.
- Non-inverting R6||C6 gain: `1+(R6/Rg)/(1+s*R6*C6)`, Rg=R7+R8 LOW or R7 HIGH. This has a 30.43 kHz pole and a gain-dependent zero, and tends to unity at high frequency. Replacing it with a simple gain low-pass would be wrong.
- Shaper: `−(R10/R9)/(1+s*R10*C7)`, corner 318.95 Hz. Output RC: `1/(1+s*R11*C8)`.

Downstream amplifiers are ideal in the pulse solver. VMID is an ideal common reference. Finite DC gain, input/output impedance, slew limiting, clamps, saturation/recovery and the host ADC are omitted. Exact pole/residue exponentials avoid a time-step approximation; a 30 ms window is stated for extrema. Rectangular equal-charge collection tests convolve the exact impulse response with current Q/width.

| 22 fC, assumed 1 nF | ADC positive peak mV | peak time µs |
|---|---:|---:|
| LOW | 141.008 | 655.55 |
| HIGH | 276.822 | 655.64 |

For HIGH, the exact legacy ideal transfer gives 279.191 mV; the full calculation changes it by -0.848%. The copied audit's sampled ideal implementation gives 279.220 mV; its initial discontinuity/time-step treatment explains that small difference. The independent copied audit solver uses a dominant-pole CSA and recursive sampled filters. Its full nominal peak is 276.821 mV; our exact dominant-pole calculation differs by 0.00033%. Adding the extra CSA pole changes the peak by 0.00000%. Transfer algebra was also cross-checked at eight frequencies (maximum relative residual 6.7e-16); the nominal loop values agree with the independent scalar unit check to numerical precision.

Equal-charge HIGH 22 fC collection examples, relative to its impulse:

| Collection width µs | peak mV | change % |
|---:|---:|---:|
| 100 | 276.546 | -0.100 |
| 500 | 270.081 | -2.435 |
| 1000 | 251.725 | -9.066 |
| 5000 | 88.310 | -68.099 |

These widths are test inputs, not measured collection-time distributions. Fast isolated-pulse calibration can map a filtered peak to collected charge. Filtering and calibration do not recover arbitrary original waveforms or charge hidden by noise. The 319 Hz shaper therefore does not establish V5 waveform fidelity or accuracy.

## Uncalibrated tolerance and headroom

`uncalibrated_tolerance_corners.csv` contains 64 selected independent corners per gain: C4/C7 ±5%, R6/Rg/R9/R10 ±1%. LOW treats R7 and R8 as moving together; HIGH bypasses R8. All other values remain nominal for this study. `one_at_a_time_passive_sensitivity.csv` separately varies all 13 modeled passive parameters, including R4/R5/C5/C6/R11/C8 and R3. Neither file is an exhaustive guaranteed tolerance bound; ADC/reference errors, fixture uncertainty, temperature, leakage, resistor excess noise and feedback stray capacitance are excluded.

| Gain | nominal mV | selected corner range mV | change from nominal % |
|---|---:|---:|---:|
| LOW | 141.008 | 129.356–154.108 | -8.26 to +9.29 |
| HIGH | 276.822 | 253.855–302.648 | -8.30 to +9.33 |

`pulse_headroom.csv` checks CSA_RAW, GAIN_RAW, SHAPED_RAW and ADC_OUT separately for 0.22–500 fC impulses at assumed 1 nF. A selected 0.1–3.2 V window is only a linear-model diagnostic, not guaranteed loaded output swing. ADC maximum alone cannot establish upstream linearity. Offsets and leakage reduce usable headroom; final-stage AC coupling can conceal a saturated CSA. At R3=100 MΩ, external 1 nA gives approximately 0.1 V DC CSA shift, 10 nA gives 1 V, and 15 nA gives 1.5 V while the loop remains linear. The separate 1.45 V budget is a deliberately smaller selected margin, not the CSV window's exact half-span.

## Noise: illustrative partial subtotal only

`partial_noise.csv` uses the finite CSA and actual downstream ideal transfer functions over 0.1 Hz–100 kHz. It includes separate CSA and downstream amplifier voltage/current noise terms, R3/R4/R5/R6/Rg/R9/R10/R11 thermal noise at 300 K, and an explicitly assumed 1 pA detector shot-noise case. Densities are extrapolated as white; that extrapolation is an assumption. The source contributions are independent in this simplified model.

| Cdet nF | LOW partial RMS µV | HIGH partial RMS µV |
|---:|---:|---:|
| 0.4 | 2310.28 | 4535.40 |
| 1.0 | 3029.69 | 5947.73 |
| 5.0 | 10802.34 | 21206.73 |

These subtotals are neither measured system RMS nor strict lower bounds. Missing terms include full frequency-dependent amplifier spectra and finite downstream responses, real detector noise, excess resistor noise, board leakage/pickup, source/charge statistics, clamp leakage/capacitance, host supply/radio coupling, temperature, ADC/reference/quantization/sampling and aliasing, and correlated VMID/reference paths. The previous independent VMID quadrature approximation has been removed: a shared reference has correlated cancellation and injection paths requiring a complete model or measurement. No SNR, threshold, energy accuracy, or complete Rev E/V5 noise ratio is inferred.

## Layout and commissioning consequences

Keep the close C2-to-U1.4 bypass connection and short ground-plane return addressed by the parent layout. Retain the existing local ground-copper void beneath SUM and its guarded high-impedance routing; adding grounded copper there would add capacitance to a sensitive node. Keep SUM and feedback paths short, clean and dry; separate the host/digital wiring and use short detector leads. Geometry recommendations do not substitute for measured supply impedance or parasitic extraction.

After assembly, record 3V3, VMID and every raw-stage baseline, darkness leakage and drift. Test high-frequency ringing/oscillation with dummy capacitance and real sensor/pigtails. Inject several independently measured charges and collection widths in both gains; measure linearity, tails, clipping/recovery, ADC reference and sample settling under host workloads. Electrical injection validates the electronics; source/background experiments and detector collection require their own evidence.

## Sources and reproduction

- [Microchip MCP602x DS20001685E](https://ww1.microchip.com/downloads/en/DeviceDoc/20001685E.pdf), AC table p.4: typical 10 MHz, 65° unity-gain phase margin, 8.7 nV/√Hz at 10 kHz and **3 fA/√Hz at 1 kHz**. The audit's statement that 3 fA was absent from that table was incorrect; it is a typical point specification, not a guaranteed broadband spectrum. Sections 4.7/4.9/4.10 cover bypassing, guarding and layout.
- [Raspberry Pi Pico 2 datasheet](https://datasheets.raspberrypi.com/pico/pico-2-datasheet.pdf): host board and ADC connections. Its nominal resolution does not establish system accuracy.
- Local authoritative topology input: preserved final-audit `Automated/CAD/Circuit.json`; 27-part topology is recorded by SHA-256 in `source_manifest.json`. The copied original implementation and independent audit scripts are retained beside this report; nothing was overwritten.

Run `Independent Validation/independent_transfer.py`, then `analog_analysis.py` with the bundled Python containing NumPy. `Independent Validation/loop_units_crosscheck.py` provides a separate scalar frequency-unit check. `analysis_results.json` contains machine-readable summary values and numerical cross-check residuals. CSVs contain the actual calculations, including the 243-corner loop scan, pulse extrema, sample waveform, selected tolerance corners, passive sensitivity and partial source-noise contributions.
