#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out=${1:-"$root/.build/uno"}
cli=${ARDUINO_CLI:-'/Applications/Arduino IDE.app/Contents/Resources/app/lib/backend/resources/arduino-cli'}
sketch="$root/Firmware/UNO R4 Minima/SignalBenchUno"
mkdir -p "$out/tmp"
out=$(cd "$out" && pwd)
export ARDUINO_DIRECTORIES_DATA="${ARDUINO_DIRECTORIES_DATA:-$HOME/Library/Arduino15}"
export ARDUINO_DIRECTORIES_DOWNLOADS="$out/downloads" ARDUINO_DIRECTORIES_USER="$out/user"
export ARDUINO_BUILD_CACHE_PATH="$out/cache" TMPDIR="$out/tmp/"
usb_flags="-O3 -include \"$sketch/SignalBenchUSB.h\""
"$cli" compile --build-property "compiler.c.extra_flags=$usb_flags" \
    --build-property "compiler.cpp.extra_flags=$usb_flags" --fqbn arduino:renesas_uno:minima \
    --build-path "$out/build" --output-dir "$out/images" "$sketch"
