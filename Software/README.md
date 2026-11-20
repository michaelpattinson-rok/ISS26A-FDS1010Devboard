# Signal Bench 3.7.11

Signal Bench build 39 requires Apple silicon and macOS 27.0 or later. Use the [locally signed DMG](Signal%20Bench/Signal%20Bench.dmg) or open the [Xcode project](Signal%20Bench/Signal%20Bench.xcodeproj) and select the Signal Bench scheme. The shared C estimator builds directly from this repository's Pico firmware source. `sh Tools/build-app.sh` from the repository root builds arm64 Release with Xcode and applies the existing App Sandbox, serial, selected file and loopback networking entitlements. See the verification and maintenance section below.

1. Create or open a named format 3 Project. Select the connected host in **Device**, then **Connect**. Check the [Pico W wiring](../Pico%20W%20to%20Devboard%20E.1%20Wiring.png) or [Uno R4 Minima wiring](../Arduino%20UNO%20R4%20Minima%20to%20Rev%20E.1%20Wiring.png).
2. For a raw run select **Main**, set the rate and duration, review the storage estimate and start. Use 100,000 samples/s and 1× for the first run. An open ADC input may float and pick up nearby signals.
3. Use **Run Library** to inspect waveform, settings, coverage, exclusions and flags. Live Details shows low and high rails and ADC errors separately. A run can retain valid samples alongside clipping and known gaps. Interrupted recordings reopen to the verified saved prefix and resume into a new segment.
4. **Export** defaults to Full Run ZIP. `Main.md` describes the contents. **Original Binary ZIP** saves the received binary without CSV conversion. Linked dark preruns appear under `calibration/` with their complete samples, timing and frozen settings. Use **Jobs** for progress, cancellation and retry.

**Manual** records live data and allows stopping and output release. **Diagnosis** records one declared probe at a time. Remove power before moving probes. **Calibrated Run** uses a matching profile and a passing 1, 5 or 15 minute dark prerun followed by a separate 5, 15, 30, 60 or 120 minute measurement. The Uno requires local timed fixture validation. If the check fails, inspect its report or select **Record Raw Anyway**. Waveform analysis retains the raw readings and reports Pulse Matches. Count rate reporting is disabled.

## Startup Delay and paused viewing

Set **Startup Delay** in **Project Settings**. New ordinary recordings default to 5 seconds. Set it to 0 to save from the start, or choose up to 30 seconds. During **Settling**, the board samples while Signal Bench skips the ADC readings. The requested recording duration starts after settling. The first saved part of a new run starts at 0 on the waveform. The Startup entry in **Sample timing and coverage** and the ZIP timing table identify the skipped interval.

Calibration checks, bench runs, the guided 60 Hz test, and standalone card capture keep their own timing. The optional Uno Device Candidates feature keeps its device-side quiet reference timing. The delay does not change the hardware or its noise.

Choose **Pause View** to hold the live waveform while the run continues. **Refresh Once** shows the latest samples in the current zoom and live window and keeps the view paused. **Follow Live** resumes automatic updates.

## Change a live duration and manage flags

The recording header shows elapsed, remaining, and target time. Use **+1 min**, **+5 min**, or **Edit Duration…** to change an ordinary USB recording or the measurement after a calibrated prerun. The target is the total logging time, excluding startup settling. Extensions check available Project space and stay within two hours. A target already reached asks you to confirm finishing the recording. Recording Details and the ZIP guide show the original and final targets and when the changes were made.

Choose **Add Flag…** to freeze the latest waveform in a separate editor while recording continues. Click a sample or enter the elapsed time in seconds and choose **Use Time**. **Save** keeps the same view ready for a new flag. **Save and Close Flag** returns to the recording. A flag can be saved with its sample still pending. If the sample never reaches disk, the label and note remain available. Use **Flag Manager…** during a recording or in Run Library to jump to, edit, move, or remove flags. The live chart groups nearby markers at wide zoom.

## Background Quality Summary

Open **Jobs** to see which run is being scanned, the readings checked, and the current stage. Signal Bench saves checkpoints in the selected Project and continues an interrupted scan when you reopen it. An explicit **Pause** stays paused until you choose **Resume**. If the recorded inputs changed, Signal Bench starts the scan again. Starting a recording takes priority over the scan.

## Live waveform and flags

Live View keeps advancing when you pan or zoom. **Jump to Live** clears the offset and **Pause View** freezes the displayed range. In **Display**, choose **Original Dots** to inspect individual readings or use averaged overview dots for wide views. The FPS goal, actual display updates, and skipped preview updates quantify the viewer separately from recording. The sidebar shows Signal Bench CPU, RAM, and Metal waveform time. Flag Manager supports **Previous Flag**, **Next Flag**, and undo for a move or removal. In the live flag editor use **⌘S** to save or **⌘Return** to save and close.

The Mac writer queue now holds up to 128 frames to absorb brief filesystem stalls. A sustained backlog triggers a controlled Stop and preserves the verified saved prefix. Run Library reports known missing readings separately.

## Sampling rates and averaging

Choose the raw rate and averaging factor directly. The three shortcuts set both controls.

| Profile | UNO R4 Minima | Pico W |
| --- | --- | --- |
| Balanced | 100,000 samples/s, 1× | 100,000 samples/s, 1× |
| Smoothed | 200,000 samples/s, 8× | 500,000 samples/s, 8× |
| Full Detail | 250,000 samples/s, 1× | 500,000 samples/s, 1× |

Uno firmware 1.1 through 1.3 accepts 10,000 to 250,000 raw samples/s, including custom requests. The GPT timer can round the configured rate. **Recorded** shows the resulting group rate. Uno firmware 1.0 works at 100,000 and 250,000 at 1×. Signal Bench blocks the old 500,000 Uno setting before recording. Higher factors preserve exact sums and counts of rail hits and ADC errors. At 1× the app retains individual ADC words.

## Uno Device Candidates

With Uno firmware 1.3, turn on **Device Candidates** at A0, 100,000 samples/s and 1×. Keep the input quiet for the first second so the device can check its reference. The option is off by default. Raw acquisition takes priority and candidate coverage can be skipped under load. In Studio, **Range Review → Compare Selected Range** shows device candidates and Mac Pulse Matches with their coverage and original sample positions. **Fixture Fit → Replay All Six Rates** compares averaging factors using separate independently timed training and held-out fixture runs. Candidate evidence remains diagnostic. Count rate reporting is disabled. On November 18, firmware 1.3 completed one 60 second USB recording with candidates off and one with candidates on. Both saved 6,000,640 consecutive raw readings without a drop. The final block of the enabled run had raw data and no candidate report.

## Import standalone Pico card recordings

Open a Project and choose **Run Library → Import Pico Card**. Select the card, its `SBRUNS` folder, or the copied SBR files. Review the verified coverage and select the runs to import. Interrupted runs require explicit selection. The app copies verified raw words and leaves the card untouched. Pico firmware 1.11 retains live USB recording while the card recorder is idle. [Firmware and wiring notes](../Firmware/README.md)

## Compare 60 Hz pickup

With a streaming Pico W, open **Diagnosis → 60 Hz Test**, use **Show Wiring** and leave J1 empty and J4 open (LOW). Compare four 20 second recordings, on battery and with the charger connected, at 100,000 and 500,000 samples/s. The app reports the 60 Hz level, clipping and coverage, and retains each raw recording in Run Library. Saved run comparisons also support Uno recordings. Compare raw codes within one board setup, or use voltage units only when the reference is known.

## Play back a saved run

Open a completed or interrupted run from **Run Library** and press **Play** beneath the waveform. The playhead follows the visible time range. Use the slider to seek, change speed from 0.25× to 25×, or return to the start of the range. Zoom for a closer review, or use **Home** to show the entire run. Saving a waveform overview with **Render Waveform** helps when reviewing long recordings. Playback shows the original time axis, including gaps and flags.

## Export several runs together

In **Run Library**, hold **⌘ Command** and click the runs you want. Click **Export ZIP…** under the list, confirm the selected runs, enter an archive name, and choose a destination. Each selected run gets a numbered folder under `Runs/`, with its settings, saved sample CSVs, timing, quality, and any applicable flags, notes, analyses, linked preruns, or curves. Standalone curve runs include the saved curve and a CSV that distinguishes exact from modeled readings.

The root `Main.md` describes the contents. `Runs.json` maps folder names to run IDs and `SHA256SUMS.txt` lists file hashes. Signal Bench reads back and verifies every entry before it publishes the ZIP and reveals it in Finder.

## Export multiple Projects

Choose **File → Export Projects as ZIP…** or use the button on the welcome screen. In the folder picker, hold **⌘ Command** and click each Signal Bench Project folder. Enter an archive name and choose a destination outside the selected folders.

The ZIP includes `Main.md`, a Project index, SHA-256 checksums and each Project in a numbered, named folder. Saved recordings, settings, flags, analyses and prior exports keep their original file formats. Unzip the archive and open any folder under `Projects/` in Signal Bench. The app decodes and verifies every entry before publishing the ZIP. It also verifies Full Run, Original Binary and Curve ZIPs.

## Review with Local AI

Local AI is optional. In Settings, connect to a loopback LM Studio endpoint, select a model, and choose **Test Tool Calling**. **Waveform Images → Test and Enable** checks image support before allowing an approved review to send one rendered waveform. Numeric review remains available without images. In Studio, ask about the selected range, Device Candidates, or averaging replay. Device Candidates requires a saved Uno run with the option enabled. Diagnostic replay compares the six averaging factors on original Uno A0 1× readings and uses the approved range only. Timed fixture validation remains a separate Studio workflow. Reviews use the approved runs in the open Project. Exclusion approval stays in Studio. The verified model was **qwen/qwen3.5-9b** with **Reasoning Off**. Use numeric results or original sample links when a model estimates timing or amplitude from a plot.

The [1.x guide](../Docs/Signal%20Bench%201.x%20Guide.pdf) documents historical controls and finite capture workflows.

Run `sh Tools/test-app.sh uno`, `sh Tools/test-app.sh prerun`, `sh Tools/test-app.sh curve` or `sh Tools/test-app.sh run-zip` for native checks with synthetic data. These cover board identity and ADC rail accounting, calibration and linked ZIPs, waveform compression and storage, or grouped run export and ZIP verification.

## Release verification and maintenance

**Maintenance release · November 19, 2026.** Signal Bench 3.7.11, build 39 updates the Xcode 27.2 project settings and moves Run Library selection and rename updates out of SwiftUI view reconciliation. The assembly PDF and [Signal Bench 1.x guide](../Docs/Signal%20Bench%201.x%20Guide.pdf) document the earlier finite capture workflow.

### Release contents

| Item | Location or version |
| --- | --- |
| Mac app | [Locally signed disk image](Signal%20Bench/Signal%20Bench.dmg) · [SHA-256 manifest](Signal%20Bench/SHA256SUMS.txt). Apple silicon, macOS 27.0 or later. |
| App source | [Signal Bench Xcode project](Signal%20Bench/Signal%20Bench.xcodeproj), scheme **Signal Bench**. The build uses the shared C estimator under Firmware. |
| Firmware | [Images, loading and checksums](../Firmware/README.md). Pico W USB 1.10, optional Pico W microSD 1.11, and UNO R4 Minima 1.3. The app update itself does not require reflashing an already compatible device. |
| Data | Format 3 Projects in folders the operator selects. Preserve the entire folder, including project.json, runs, settings, analyses, and any Exports. Open the Project folder to continue work. |

To replace an open older build, stop and save the current run, quit Signal Bench, and open the app from the current disk image. Confirm version **3.7.11 (39)** in **About Signal Bench**. Verify the checksum from the Devboard E root:

```sh
(cd 'Software/Signal Bench' && shasum -a 256 -c SHA256SUMS.txt)
```

### Prior hardware and release evidence

| Check | Observed result and limits |
| --- | --- |
| Mac release | The prior 3.7.6 canonical source built as arm64 Release. The compressed disk image, extracted app signature, build number, and delivered checksum verified. Native offline regressions and Local AI settings snapshots passed. |
| Uno USB transport | Firmware 1.3 at A0, 100,000 samples/s and 1× saved 6,000,640 samples in each of two approximately 60 second runs, with Device Candidates off and on. Both reconciled cleanly at Stop with zero raw drops and zero ADC errors. The enabled run lacked the last 1,024-reading candidate report. The raw block was intact. |
| Pico USB transport | A short GP26 check on 1.11 saved 202,752 contiguous samples at nominal 100,000 samples/s. Earlier 1.8.3 tests reached 500,000 samples/s for six minutes without raw drops, with significant analog clipping. Those tests establish transport for their respective setups and durations. |
| Pico card import | The importer replayed a synthetic 30 minute file and verified all 180 million ADC words and their timing. The physical card preflight returned an error during the 1.11 check. A physical card write and import remain unverified. |
| Startup delay and refresh | With Uno 1.3, a 30 second test at 100,000 samples/s and 1× ended after 35.075 seconds including the five second delay. It saved 3,006,176 readings with zero drops. The frozen waveform test advanced only on refresh. |
| Local AI | The real local model **qwen/qwen3.5-9b**, with **Reasoning Off**, completed waveform image, Device Candidates and averaging replay requests on a synthetic Uno Project. The model recognized the waveform dip and misread its pulse duration and amplitude. Use the original sample positions and Swift computed results for exact values. |

The supporting release, USB, and model logs are indexed in the ISS workspace under **Agents → Reviews → Signal Bench Startup and Live Refresh** and **Signal Bench Local AI Waveform Evidence**. They identify the exact test fixtures, software versions and earlier hardware evidence.

### Version 3.7.7 verification

The software validation and Uno Nothing replay are recorded under **Agents → Reviews → Signal Bench Live Run Controls**. The release uses the existing firmware.

### Versions 3.7.8 through 3.7.10 verification

The app archive was mounted and its arm64 signature, build number, and checksum verified. Offline tests exercised continuous waveform navigation, real Metal drawing on the test Mac, and flag edits. The Uno writer regression reproduced a 63 ms stall at 250,000 samples/s and verified zero loss with the expanded queue. An 800 ms stall still forced a bounded Stop and preserved the verified prefix. The Uno connected over USB was flashed with the released 1.3 image and reported the correct target and version afterward. These checks establish the specified software and USB behaviors. Physical measurement accuracy remains a separate validation step.

### Operating limits

Start at **100,000 samples/s and 1×** with a known input. Raw data can record while detector calibration is unavailable. A completed run can still contain clipping, ADC errors or loss. Read the coverage and quality indicators before using the waveform. For weak pulses, keep original readings for later analysis. Averaging can attenuate narrow pulses, and a modeled curve cannot restore discarded originals.

**Pulse Matches** and **Device Candidates** are diagnostic. Count rate reporting is disabled and rate_exposure_valid remains zero. A quiet baseline, complete transport, or a fixture match does not establish detector response, calibrated energy or dose. Before relying on unattended or calibrated measurements, validate the intended duration, board, input, rate and averaging using controlled empty-board, dark detector and independently timed fixture runs. For standalone recording, also verify a complete physical card and power bank session followed by import.

### Maintenance

- Back up complete Project folders and retain original ADC records before analysis or space saving. Keep exports with their manifests. Reopen interrupted runs at their verified saved prefix. Continuing writes a new timing segment.
- Use the existing build and test scripts from the Devboard E root. Pass an explicit output directory. The closeout build environment had Xcode 27.2 installed.
- Keep firmware packages and app releases separately versioned. Before promoting a future build, rerun the affected native tests, check the signed artifact and checksum, and document any additional real USB, model or bench evidence.

```sh
sh Tools/build-app.sh "/path/to/build-output"
sh Tools/test-app.sh uno "/path/to/test-output"
sh Tools/test-app.sh prerun "/path/to/test-output"
sh Tools/test-app.sh run-zip "/path/to/test-output"
```
