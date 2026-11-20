# Signal Bench 3.7.10 release and maintenance

**Maintenance release · November 19, 2026.** Signal Bench 3.7.10, build 38 combines resumable Quality Summary, live duration edits, Flag Manager, direct Metal drawing, activity meters, and the Mac writer stall fix. The [app guide](README.md) is the current operator reference. The assembly PDF and [Signal Bench 1.x guide](../Docs/Signal%20Bench%201.x%20Guide.pdf) document the earlier finite capture workflow.

## Release contents

| Item | Location or version |
| --- | --- |
| Mac app | [Locally signed disk image](Signal%20Bench/Signal%20Bench.dmg) · [SHA-256 manifest](Signal%20Bench/SHA256SUMS.txt). Apple silicon, macOS 27.0 or later. |
| App source | [Signal Bench Xcode project](Signal%20Bench/Signal%20Bench.xcodeproj), scheme **Signal Bench**. The build uses the shared C estimator under Firmware. |
| Firmware | [Images, loading and checksums](../Firmware/README.md). Pico W USB 1.10, optional Pico W microSD 1.11, and UNO R4 Minima 1.3. The app update itself does not require reflashing an already compatible device. |
| Data | Format 3 Projects in folders the operator selects. Preserve the entire folder, including project.json, runs, settings, analyses, and any Exports. Open the Project folder to continue work. |

To replace an open older build, stop and save the current run, quit Signal Bench, and open the app from the current disk image. Confirm version **3.7.10 (38)** in **About Signal Bench**. Verify the checksum from the Devboard E root:

```sh
(cd 'Software/Signal Bench' && shasum -a 256 -c SHA256SUMS.txt)
```

## Prior hardware and release evidence

| Check | Observed result and limits |
| --- | --- |
| Mac release | The prior 3.7.6 canonical source built as arm64 Release. The compressed disk image, extracted app signature, build number, and delivered checksum verified. Native offline regressions and Local AI settings snapshots passed. |
| Uno USB transport | Firmware 1.3 at A0, 100,000 samples/s and 1× saved 6,000,640 samples in each of two approximately 60 second runs, with Device Candidates off and on. Both reconciled cleanly at Stop with zero raw drops and zero ADC errors. The enabled run lacked the last 1,024-reading candidate report. The raw block was intact. |
| Pico USB transport | A short GP26 check on 1.11 saved 202,752 contiguous samples at nominal 100,000 samples/s. Earlier 1.8.3 tests reached 500,000 samples/s for six minutes without raw drops, with significant analog clipping. Those tests establish transport for their respective setups and durations. |
| Pico card import | The importer replayed a synthetic 30 minute file and verified all 180 million ADC words and their timing. The physical card preflight returned an error during the 1.11 check. A physical card write and import remain unverified. |
| Startup delay and refresh | With Uno 1.3, a 30 second test at 100,000 samples/s and 1× ended after 35.075 seconds including the five second delay. It saved 3,006,176 readings with zero drops. The frozen waveform test advanced only on refresh. |
| Local AI | The real local model **qwen/qwen3.5-9b**, with **Reasoning Off**, completed waveform image, Device Candidates and averaging replay requests on a synthetic Uno Project. The model recognized the waveform dip and misread its pulse duration and amplitude. Use the original sample positions and Swift computed results for exact values. |

The supporting release, USB, and model logs are indexed in the ISS workspace under **Agents → Reviews → Signal Bench Startup and Live Refresh** and **Signal Bench Local AI Waveform Evidence**. They identify the exact test fixtures, software versions and earlier hardware evidence.

## Version 3.7.7 verification

The software validation and Uno Nothing replay are recorded under **Agents → Reviews → Signal Bench Live Run Controls**. The release uses the existing firmware.

## Versions 3.7.8 through 3.7.10 verification

The app archive was mounted and its arm64 signature, build number, and checksum verified. Offline tests exercised continuous waveform navigation, real Metal drawing on the test Mac, and flag edits. The Uno writer regression reproduced a 63 ms stall at 250,000 samples/s and verified zero loss with the expanded queue. An 800 ms stall still forced a bounded Stop and preserved the verified prefix. The Uno connected over USB was flashed with the released 1.3 image and reported the correct target and version afterward. These checks establish the specified software and USB behaviors. Physical measurement accuracy remains a separate validation step.

## Operating limits

Start at **100,000 samples/s and 1×** with a known input. Raw data can record while detector calibration is unavailable. A completed run can still contain clipping, ADC errors or loss. Read the coverage and quality indicators before using the waveform. For weak pulses, keep original readings for later analysis. Averaging can attenuate narrow pulses, and a modeled curve cannot restore discarded originals.

**Pulse Matches** and **Device Candidates** are diagnostic. Count rate reporting is disabled and rate_exposure_valid remains zero. A quiet baseline, complete transport, or a fixture match does not establish detector response, calibrated energy or dose. Before relying on unattended or calibrated measurements, validate the intended duration, board, input, rate and averaging using controlled empty-board, dark detector and independently timed fixture runs. For standalone recording, also verify a complete physical card and power bank session followed by import.

## Maintenance

- Back up complete Project folders and retain original ADC records before analysis or space saving. Keep exports with their manifests. Reopen interrupted runs at their verified saved prefix. Continuing writes a new timing segment.
- Use the existing build and test scripts from the Devboard E root. Pass an explicit output directory. The closeout build environment had Xcode 27.2 installed.
- Keep firmware packages and app releases separately versioned. Before promoting a future build, rerun the affected native tests, check the signed artifact and checksum, and document any additional real USB, model or bench evidence.

```sh
sh Tools/build-app.sh "/path/to/build-output"
sh Tools/test-app.sh uno "/path/to/test-output"
sh Tools/test-app.sh prerun "/path/to/test-output"
sh Tools/test-app.sh run-zip "/path/to/test-output"
```
