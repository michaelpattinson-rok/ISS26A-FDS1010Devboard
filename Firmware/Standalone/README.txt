FDS1010 REV E.1 — ISOLATED-PULSE DEMONSTRATION FIRMWARE
Final E.1 source package. All six MCU target builds remain NOT RUN. Native
processing/stub tests do not establish target or hardware qualification. No
hardware was programmed/tested or software/core/SDK installed/downloaded in this
verification.

SUPPORTED SOURCE TARGETS AND THREE-WIRE CONNECTION
Pico / Pico W (RP2040), Pico 2 / Pico 2 W (RP2350): common C/SDK source.
Classic Uno R3 / Nano, 16MHz ATmega328P: Arduino/RevE_Arduino/RevE_Arduino.ino.
Uno R4, Nano Every, Nano 33 and other boards are not AVR sketch targets.
One powered host only. Power OFF before wiring or changing physical gain.
Board J2.1 GND -> Pico physical33 AGND OR Arduino GND.
Board J2.2 3V3 <- Pico physical36 3V3 OUT OR verified Arduino 3.3V output.
Board J2.3 ADC_OUT -> Pico physical31 GP26/ADC0 OR Arduino A0.
Never connect 5V, VBUS, VSYS, VIN, AREF or an Arduino digital output to the board.
Leave AREF unwired; use DEFAULT AVcc for classic Arduino. The board stays3.3V.
J1 connects the detector OR passive test fixture, never both. Neither detector
lead is ground. Check unkeyed pin numbers and voltages before powering.
Official Uno 3.3V output rating is50mA; engineering board budget is under10mA.
Classic Nano FT232RL-derived3.3V requires USB power; clone bridges/power trees
vary. Verify3.3V under load; never substitute5V if a suitable3.3V source is absent.
Host/board hotplug and power-off ADC isolation remain unqualified.

PICO: CONSERVATIVE ISOLATED HEIGHTS, NOT A TAIL FIT
GP26 digital input/pulls off; ADC0 only;100000sps requested;32768 retained12bit
DMA samples (~327.68ms). One-second settle and32 discarded conversions precede
capture. CPU analysis/printing occurs afterwards. Ordinary USB interrupts remain.
No CYW43/network library or radio initialization; no direct GPIO23 writes.
The32 warmup samples now use a bounded FIFO discard (50ms deadline or one million
polls), so startup no longer hangs inside SDK adc_read() before the DMA timeout.
A failed warmup aborts with ACQ_TIMEOUT, zero retained samples and no raw record.
First2048 samples (20.48ms) establish the initial pedestal/noise. Last10000
samples (100ms) are an end guard: nominal trigger window is207.2ms before any
exclusion, not measured radiation exposure. Threshold is max24codes/6sigma,
or the frozen quiet-calibration value. Raising the floor from12 to24 deliberately
sacrifices small-pulse sensitivity. Frozen threshold must still exceed local noise.
Each candidate blocks the next10000samples (100ms from its threshold crossing).
This interval is BLIND to an independent pulse-height measurement. A renewed
positive excursion may flag pileup and reject the whole record; a small hidden
pulse need not be identifiable. No amplitude for that hidden pulse is reported.
The four-sample width gate now requires four CONTIGUOUS above-threshold samples;
four separated one-sample spikes cannot satisfy it, including equality cases.
A candidate uses the median of512 preceding samples (5.12ms). Both its offset
from initial pedestal and the median difference between its two256-sample halves
must be <=1code; local sigma must meet the frozen6sigma threshold/noise limits.
Candidate CSV includes local baseline, offset, slope, local sigma, the1code
baseline/slope tolerances, contiguous width and flags. Peak is relative to that
local pedestal. Any processing/acquisition defect rejects the entire record.
Raw candidate_delta fields are DIAGNOSTIC; height_qualified=0 when calibration,
fixture mode, acquisition error or any record-quality defect prevents use.
height_qualified=1 means this restricted estimator passed its gates, not that
hardware absolute amplitude/charge/energy precision has been established.
No fitted pulse or tail subtraction is used. Nominal model tests are not a bound
for another RC response, component tolerances, real noise or amplifier saturation.
Unresolved near-coincident pulses and pedestal changes that start during a pulse
can escape a pre-event/peak heuristic; do not treat a height as single-particle
energy. Inspect CSA_RAW and GAIN_RAW too: downstream filtering can hide clipping.

ARDUINO: ONE PULSE IN A FIXED SMALL TRIGGER WINDOW
The same3.3V board uses A0, no pullup, AVcc reference (~5V), nominal10bit ADC.
ADC16MHz/128,13 clocks/conversion: nominal104us/sample (~9615sps). Discard16
conversions; retain256samples (~26.624ms). Serial output is flushed before
capture. No analysis/printing occurs in capture. Timer/serial interrupts remain:
whole-record +/-10percent timing guard cannot prove regular sample intervals.
Every warmup/retained conversion has a1ms timeout and16000poll fallback if the
timer stalls. Timeout disables ADC, rejects/clears the record and prevents raw
output of partially filled data; another command can retry. This is host-tested
control flow with fake registers, not an AVR timer/register/hardware test.
The AVR automatic threshold is max(4codes,6initial_sigma); its frozen quiet
threshold must still meet the current noise check. This differs from the Pico
24code floor; ADC code size and sample rate also differ.
Only ONE threshold crossing in sample64..127 is eligible (nominal6.656..13.208ms;
window ends13.312ms). First32 samples establish baseline/noise. A positive pulse
outside this window, multiple crossings, clipping, bad width or a positive lobe
reaching the final16samples rejects the record. Ordinary late negative tail from
the sole complete positive lobe no longer causes an amplitude-dependent veto.
A32sample pre-event mean and its two16sample half means qualify local pedestal,
slope and noise. Offset/slope tolerance is max1code/0.5initial_sigma, reported
with each candidate. Local peak is relative to this pedestal. Failed recovery or
drift never produces an accepted height. This gate does not identify all hidden
or mutually unresolved pulses. The64sample trigger window is NOT calibrated
exposure or an amplitude-independent physical-onset efficiency.
Set FDS_AVR_AVCC_MV and FDS_BOARD_3V3_MV to measured rails. Defaults5000/3300mV.
Analog-rail guard is approximately10/665codes at5V AVcc (50mV headroom), not just
0/1023. It cannot detect every upstream saturation. No Arduino fixture output.
636bytes native capture/result plus64reserve is below the800byte application
state limit; actual AVR core buffers, link map and stack in2KiB are unverified.

COMMANDS, CALIBRATION AND SERIAL OUTPUT
AVR serial is115200baud; Pico uses USB stdio. Commands are single characters.
Command | Action
c       | Capture quiet dark calibration; freeze noise threshold only on success.
b / s   | Capture a background/source-tagged record; successful c is required.
d       | Dump last retained raw record as CSV; no new acquisition.
l / h   | LOW/HIGH physical-gain metadata; clear calibration; run c again.
?       | Print help.
t       | Pico fixture-only capture, compile-time OFF unless explicitly enabled.
Changing l/h never moves J4: physical LOW=open27.15, HIGH=shunt53.3. Change the
jumper with power OFF. Calibration must be quiet over the FULL retained record,
including guards. c is a noise-threshold calibration, not ADC/charge/energy
calibration. Pico t requires FDS_ENABLE_FIXTURE=ON and detector removed; GP15 is
input otherwise. There is no Arduino fixture command/output.

Output / fields                         | Meaning
Pico record=...,tag=...,n=...,sample_hz   | One record summary and nominal sampling.
acq_flags / quality_flags               | Hex acquisition/processing bitmasks; any
                                        | defect prevents a usable Pico record.
Pico event,...,candidate_delta_codes    | Diagnostic local-baseline-subtracted
candidate_delta_mV_nominal              | height; mV uses nominal3300/4096.
local_baseline/offset/slope/sigma fields | Measured pre-event pedestal checks;
baseline/slope_tolerance_codes          | printed tolerances are in ADC codes.
Pico height_qualified                   | Boolean: 1 only for usable b/s record
                                        | with no event flags; otherwise 0.
Pico event flags                        | Hex bitmask: 0 means no event flags.
                                        | Passing gates is not measured accuracy
                                        | or proof of a single-particle event.
Pico rate_exposure_valid=0              | count_live_s/observation/dead/session
                                        | windows are NOT a valid rate denominator.
AVR diagnostic_local_peak_codes        | Sole candidate peak relative to local
peak_status / accepted / flags          | mean; status isolated_demo_only only
                                        | when accepted=1, else unqualified.
                                        | flags is a decimal processing bitmask.
AVR rate_exposure_us=unqualified        | No unbiased exposure/rate correction.
Pico d: # RAW_BEGIN / # RAW_END          | Raw CSV columns: index,time_us_nominal,
                                        | raw12,adc_error,signed_delta_codes.
                                        | Raw delta uses INITIAL record baseline,
                                        | not each event's local baseline.
AVR d                                  | sample,nominal_us,adc_code,approx_mv;
                                        | mV uses configured AVcc, not calibration.
raw_us / gap_before_us / blind_gap_us    | Capture duration and gaps (host-specific
approx_blind_s and session fields       | names); settling/output/user gaps blind.
Pico flag definitions: pulse_estimator.h and main.c acq_flags. AVR flag definitions:
Arduino/RevE_Arduino/avr_detector.h. Timeout prevents an AVR partial/stale raw dump;
Pico raw with an acquisition defect remains diagnostic and retains its flags.

BLIND TIME AND CLAIM LIMITS
Settling, discarded conversions, analysis, serial dumps and user waits are blind.
Even with zero other overhead, repeated Pico commands retain at most about24.7%
raw wall time and15.6% nominal pre-exclusion trigger-window time. AVR retains at
most about2.6% raw wall time and0.65% nominal trigger-window time. These are
arithmetic upper bounds, not measured duty cycle or useful radiation exposure.
Quality rejection and100ms Pico exclusion further reduce opportunity. Output
rate_exposure_valid=0 states that nominal sample-window counters are NOT an
unbiased rate denominator. No count-rate/deadtime/pileup correction is justified.
Keep short common-ground wiring, opaque dry detector enclosure, clean input and
radio off. Real rail ripple, ADC noise/reference error, timing, diode leakage,
capacitance, stability, ringing and repeat-pulse recovery require bench tests.
No V5-equivalent accuracy, energy/dose calibration, efficiency or source-response
claim is made. Higher gain/sample count/nominal ADC bits do not establish these.

BUILD WITH EXISTING TOOLS ONLY
Requires existing Pico SDK2.x/TinyUSB, CMake and matching compiler. Source support:
  cmake -S <Firmware> -B <inside-Agents>/build-<board> -DPICO_BOARD=<pico|pico_w|pico2|pico2_w> -DPICO_SDK_PATH=/existing/pico-sdk
  cmake --build <inside-Agents>/build-<board>
Downloads/fetches are disabled; no picotool/UF2 promise. For AVR use an existing
Arduino AVR core/IDE/CLI, Uno or classic Nano16MHz. No core is fetched.

AVR compile-only examples, NOT RUN. Use an ALREADY installed arduino-cli, Arduino
AVR Boards core and its compiler. From this Firmware directory, substitute an
absolute existing/creatable build directory INSIDE Agents for <Agents-build>:
  mkdir -p "<Agents-build>/tmp" "<Agents-build>/cache"
  export TMPDIR="<Agents-build>/tmp"
  export ARDUINO_BUILD_CACHE_PATH="<Agents-build>/cache"
  arduino-cli compile --fqbn arduino:avr:uno --build-path "<Agents-build>/uno" "Arduino/RevE_Arduino"
  arduino-cli compile --fqbn arduino:avr:nano:cpu=atmega328 --build-path "<Agents-build>/nano" "Arduino/RevE_Arduino"
For a known classic Nano with old bootloader, the compile FQBN is
arduino:avr:nano:cpu=atmega328old; use a separate build-nano-old directory.
These commands compile only: no upload flag/command is included or run. If the
CLI/core/compiler is absent, record NOT RUN; do not install/download it here.
IDE board selections (reference only; NOT RUN): Arduino AVR Boards > Arduino Uno;
or Arduino AVR Boards > Arduino Nano, Processor > ATmega328P (or ATmega328P
(Old Bootloader) only for the matching Nano). Both supported targets are16MHz
ATmega328P. Do not choose ATmega168, Uno R4, Nano Every or Nano33. Open
Arduino/RevE_Arduino/RevE_Arduino.ino; Verify/Compile is separate from Upload.
Workspace build artifacts, temporary files and caches must remain inside Agents.
Official CLI flags/configuration and AVR board IDs are linked in Host Compatibility.md.
Current preflight: no CMake, Ninja, ARM compiler, AVR compiler, arduino-cli or
configured Pico SDK. ALL SIX target builds NOT RUN; no hardware programmed/tested.
Native declaration-stub syntax checks do not validate a real SDK or Arduino core.

REPRODUCE LOCAL CHECKS
  python3 run_verification.py <absolute-output-directory-inside-Agents>
Tests include the exact ideal five-pole nominal circuit cascade (CSA1ms,
C5/R5HP10.1ms, R6||C6 pole+gain zero,499us shaper,1us ADC RC), quantization,
both gains, amplitude/separation/phase sweeps, pre-record pulses, local pedestal
steps/slopes, separated spikes and acquisition timeout branches. Empirical
accepted-model errors are in
../Docs/Verification/Firmware/Firmware Changes and Evidence.md.
These are finite deterministic synthetic checks, not hardware accuracy bounds.
Changing timing, threshold, windows or baseline tolerances invalidates this finite
validation; custom configurations require their own validation.
