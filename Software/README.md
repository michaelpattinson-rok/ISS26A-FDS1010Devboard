# Signal Bench 3.6.1

Signal Bench build 23 requires Apple silicon and macOS 27.0 or later. Use the [locally signed DMG](Signal%20Bench/Signal%20Bench.dmg) or open the [Xcode project](Signal%20Bench/Signal%20Bench.xcodeproj) and select the Signal Bench scheme. The shared C estimator builds directly from this repository's Pico firmware source. `sh Tools/build-app.sh` from the repository root builds arm64 Release with Xcode and applies the existing App Sandbox, serial, selected file and loopback networking entitlements.

1. Create or open a named format 3 Project. Select the connected host in **Device**, then **Connect**. Check the [physical connections](../Pico%20W%20and%20UNO%20R4%20Minima%20to%20Rev%20E.1%20Wiring.png).
2. For a raw run select **Main**, set the rate and duration, review the storage estimate and start. Use 100,000 samples/s and 1× for the first run. An open ADC input may float and pick up nearby signals.
3. Use **Run Library** to inspect waveform, settings, coverage, exclusions and flags. Live Details shows low and high rails and ADC errors separately. A run can retain valid samples alongside clipping and known gaps. Interrupted recordings reopen to the verified saved prefix and resume into a new segment.
4. **Export** defaults to Full Run ZIP. `Main.md` describes the contents. **Original Binary ZIP** saves the received binary without CSV conversion. Linked dark preruns appear under `calibration/` with their complete samples, timing and frozen settings. Use **Jobs** for progress, cancellation and retry.

**Manual** records live data and allows stopping and output release. **Diagnosis** records one declared probe at a time. Remove power before moving probes. **Calibrated Run** uses a matching profile and a passing 1, 5 or 15 minute dark prerun followed by a separate 5, 15, 30, 60 or 120 minute measurement. The Uno requires local timed fixture validation. If the check fails, inspect its report or select **Record Raw Anyway**. Waveform analysis retains the raw readings and reports Pulse Matches. Count rate reporting is disabled.

Local AI is optional. Connect to a loopback LM Studio endpoint in Settings and select an available model. Reviews use the approved runs in the open Project. Exclusion approval stays in Studio. The [1.x guide](../Docs/Signal%20Bench%201.x%20Guide.pdf) documents historical controls and finite capture workflows.

Run `sh Tools/test-app.sh uno`, `sh Tools/test-app.sh prerun` or `sh Tools/test-app.sh curve` for native checks with synthetic data. These cover board identity and ADC rail accounting, calibration and linked ZIPs, or waveform compression and storage.
