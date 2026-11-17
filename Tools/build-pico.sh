#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out=${1:-"$root/.build/pico"}
tools=${PICO_TOOLS_DIR:-"$HOME/.pico-sdk"}
sdk=${PICO_SDK_PATH:-"$tools/sdk/2.3.1"}
toolchain=${PICO_TOOLCHAIN_PATH:-"$tools/toolchain/15_2_Rel1"}
cmake=${CMAKE:-"$tools/cmake/v4.3.4/CMake.app/Contents/bin/cmake"}
ninja=${NINJA:-"$tools/ninja/v1.13.2/ninja"}
picotool=${PICOTOOL:-"$tools/picotool/2.3.1/picotool/picotool"}
mkdir -p "$out/tmp"
out=$(cd "$out" && pwd)
export TMPDIR="$out/tmp/"
"$cmake" -S "$root/Firmware/Pico" -B "$out" -G Ninja \
    "-DCMAKE_MAKE_PROGRAM=$ninja" -DCMAKE_BUILD_TYPE=Release -DPICO_BOARD=pico_w \
    "-DPICO_SDK_PATH=$sdk" "-DPICO_TOOLCHAIN_PATH=$toolchain" -DFDS_ENABLE_FIXTURE=OFF
"$cmake" --build "$out" --target signal_bench_stream signal_bench fds1010_reve
"$picotool" uf2 convert "$out/signal_bench_stream.elf" "$out/Signal Bench Pico W 1.10.uf2" \
    --family 0xe48bff56 --platform rp2040
"$picotool" info -a "$out/Signal Bench Pico W 1.10.uf2"
