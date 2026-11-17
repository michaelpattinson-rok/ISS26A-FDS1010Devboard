#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out=${1:-"$root/.build/firmware-tests"}
pico="$root/Firmware/Pico"
mkdir -p "$out/tmp"
out=$(cd "$out" && pwd)
export TMPDIR="$out/tmp/" CLANG_MODULE_CACHE_PATH="$out/modules" PYTHONDONTWRITEBYTECODE=1
python3 "$root/Firmware/Standalone/run_verification.py" "$out/standalone"
sh "$pico/tests/run_host_tests.sh" "$out/pico"
"${CC:-clang}" -std=c11 -Wall -Wextra -Werror -O2 -I "$pico" \
    "$pico/tests/PicoAverageChecks.c" -o "$out/pico-average"
"$out/pico-average"
for check in check_burst check_observe check_signal_bench; do
    python3 "$pico/tests/$check.py" "$out/$check"
done
