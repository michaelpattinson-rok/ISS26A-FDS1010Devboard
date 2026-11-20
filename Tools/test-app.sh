#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mode=${1:-uno}
output=${2:-"$root/.build/app-tests"}
tests="$root/Software/Tests"
source="$root/Software/Signal Bench/Signal Bench"
estimator="$root/Firmware/Pico"
developer=$(xcode-select -p)
compiler="$developer/Toolchains/XcodeDefault.xctoolchain/usr/bin"
sdk=$(xcrun --sdk macosx --show-sdk-path)
case "$mode" in
  uno) suite="$tests/UnoChecks.swift"; flag=UNO_CHECKS ;;
  prerun) suite="$tests/PrerunChecks.swift"; flag=UNO_CHECKS ;;
  curve) suite=""; flag=CURVE_TESTING ;;
  project-zip) suite="$tests/ProjectArchiveChecks.swift"; flag=UNO_CHECKS ;;
  playback) suite="$tests/RunPlaybackChecks.swift"; flag=UNO_CHECKS ;;
  pico-card) suite="$tests/PicoCardChecks.swift"; flag=UNO_CHECKS ;;
  mains-hum) suite="$tests/MainsHumChecks.swift"; flag=UNO_CHECKS ;;
  run-zip) suite="$tests/RunBatchArchiveChecks.swift"; flag=UNO_CHECKS ;;

  *) printf '%s\n' 'Use uno, prerun, curve, project-zip, playback, run-zip, mains-hum or pico-card.' >&2; exit 2 ;;
esac
mkdir -p "$output/tmp"
directory=$(mktemp -d "$output/run.XXXXXXXX")
export TMPDIR="$directory/" CFFIXED_USER_HOME="$directory"
trap 'rm -rf -- "$directory"' EXIT
"$compiler/clang" -O2 -c -mmacosx-version-min=27.0 -isysroot "$sdk" -I "$estimator" \
    "$source/SignalBenchProcessing.c" -o "$directory/core.o"
set -- "$tests/CurveChecks.swift" "$tests/StudioRangeChecks.swift"
if [ -n "$suite" ]; then set -- "$@" "$suite"; fi
while IFS= read -r name; do
    set -- "$@" "$source/$name.swift"
done < "$tests/Sources.txt"
"$compiler/swiftc" -O -whole-module-optimization -D STREAM_TESTING -D REVIEW_WORKER_TESTING \
    -D "$flag" -disable-sandbox -parse-as-library -swift-version 5 -target arm64-apple-macosx27.0 \
    -sdk "$sdk" -module-cache-path "$directory/modules" -Xcc "-I$estimator" \
    -import-objc-header "$source/SignalBench-Bridging-Header.h" "$@" "$directory/core.o" -o "$directory/validation"
"$directory/validation" "$directory"
