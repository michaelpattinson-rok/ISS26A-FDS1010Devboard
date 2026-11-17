# Firmware

| Hardware | Source | Image and build |
| --- | --- | --- |
| Raspberry Pi Pico W, original RP2040 | [Pico](Pico/) | [1.10 UF2](Images/Signal%20Bench%20Pico%20W%201.10.uf2). Run `sh Tools/build-pico.sh` from the repository root. |
| Arduino UNO R4 Minima, Renesas RA4M1 | [SignalBenchUno](UNO%20R4%20Minima/SignalBenchUno/) | [1.0 BIN](Images/Signal%20Bench%20UNO%20R4%20Minima%201.0.bin). Run `sh Tools/build-uno.sh`. |
| Legacy standalone hosts | [Standalone](Standalone/) | The earlier Pico family and classic ATmega328P Uno/Nano acquisition sketches and tests. Classic AVR and Uno R4 Minima are different targets. |

Pico builds use an installed Pico SDK 2.3.1 with TinyUSB, Arm GNU 15.2.1, CMake, Ninja and picotool. The script defaults to the standard Pico VS Code extension tool folders. Set `PICO_SDK_PATH`, `PICO_TOOLCHAIN_PATH`, `CMAKE`, `NINJA` and `PICOTOOL` if your installed tools are elsewhere. The image used by Signal Bench comes from **signal_bench_stream** on `pico_w`. Its separate finite and legacy targets are retained. For programming, hold BOOTSEL while reconnecting USB, then copy the released UF2 to RPI-RP2. When it reboots, connect in Signal Bench and check firmware 1.10 in the status bar.

The Uno build uses the Renesas UNO core 1.6.0 and Arduino CLI. Set `ARDUINO_CLI` and `ARDUINO_DIRECTORIES_DATA` if necessary. The build includes the USB header for both C and C++ with the tested compiler flags. To load the rebuilt image, use the Minima USB port and the build's image directory with the installed CLI.

```sh
arduino-cli upload --fqbn arduino:renesas_uno:minima --port /dev/cu.usbmodemYOURDEVICE \
  --input-dir .build/uno/images "Firmware/UNO R4 Minima/SignalBenchUno"
```

Check the connected board type and serial port before uploading. Verify the bundled images with `(cd Firmware/Images && shasum -a 256 -c SHA256SUMS.txt)`. The build scripts compile locally. `sh Tools/test-firmware.sh` runs native, sanitizer, simulated SDK and protocol checks. The [Pico protocol](Pico/README.md) describes binary framing, averaging and device stop codes.

For initial recording, use Main at **100,000 samples/s, 1×**. Pico W keeps 12 bit ADC words and flags. Its optional AVG1 modes record group sums and fault counters. The Uno keeps 14 bit ADC words; enable Bench Rates. Uno A0 transported 100,000 and 250,000 samples/s for ten minutes each. At 500,000, the ADC transfer failed to rearm. Pico and Uno rate evidence measures transport, while stable input, dark detector and fixture tests qualify waveform behavior separately. [Firmware identity and USB summaries](../Docs/Verification/)
