# Rev E analysis correction summary

The analysis was corrected without changing any hardware value, BOM, CAD, or firmware. All results below are calculations for an unqualified prototype, not measurements or a V5 accuracy guarantee.

- Corrected the Hz/rad/s extra-pole defect. The intended 21.445 MHz pole had been implemented at 134.743 MHz. All **243 loop corners** rerun; selected-model phase-margin range **89.275–89.668°**. This does not qualify the real board's stability.
- Added actual R4/C5/R5 coupling, the **non-inverting R6||C6 zero and pole**, finite two-pole CSA, shaper and output RC. At assumed 1 nF and 22 fC impulse, predicted LOW/HIGH ADC peaks are **141.008/276.822 mV** at approximately 656 µs. The independent recursive pulse model agrees with our exact dominant-pole solution to **0.00033%**.
- Selected HIGH component corners give **253.855–302.648 mV**, approximately **−8.30/+9.33%** before calibration. This selected six-parameter sweep is not a guaranteed all-error bound. Collection width also matters: a 1 ms equal-charge pulse loses about 9.1% peak; 5 ms loses about 68.1%.
- Added downstream resistor and amplifier sources to the illustrative noise calculation. At assumed 1 nF, partial LOW/HIGH RMS is **3.030/5.948 mV** over 0.1 Hz–100 kHz. The result excludes real detector, correlated VMID, ADC/aliasing, pickup and several other sources, so it establishes no total noise, detection threshold or accuracy.
- Corrected an audit-source detail: Microchip's AC table does list **3 fA/√Hz typical at 1 kHz**. Treating it or 8.7 nV/√Hz as a broadband white spectrum remains a modeling assumption.

Keep the existing C4=10 pF and ground-copper void under SUM. C2's short bypass path is handled by the parent layout. After assembly, verify raw-stage baselines, leakage/drift, high-frequency stability, measured charge/width linearity and ADC/reference behavior before making accuracy claims.

Detailed equations, limitations and primary references: [Analog Analysis.md](Analog%20Analysis.md). Reproducible source: `analog_analysis.py`; machine summary: `analysis_results.json`; numeric evidence: `tia_loop_scan.csv`, `finite_bandwidth_charge_pulses.csv`, `pulse_headroom.csv`, `uncalibrated_tolerance_corners.csv`, `one_at_a_time_passive_sensitivity.csv` and `partial_noise.csv`. Unchanged audit scripts and their rerun outputs are in `Independent Validation/`. To rerun the analysis and regenerate input hashes, use `sh Tools/analyze-board.sh` from the repository root with NumPy available.
