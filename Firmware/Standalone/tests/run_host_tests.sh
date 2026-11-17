#!/bin/sh
set -eu
src=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out=${1:?Provide an output directory}
mkdir -p "$out/tmp" "$out/ModuleCache"
export TMPDIR="$out/tmp"
export CLANG_MODULE_CACHE_PATH="$out/ModuleCache"
cc=${CC:-/usr/bin/clang}
"$cc" -std=c11 -Wall -Wextra -Werror -pedantic -O2 "$src/pulse_estimator.c" "$src/tests/test_estimator.c" -lm -o "$out/test_estimator"
"$out/test_estimator"
"$cc" -std=c11 -Wall -Wextra -Werror -pedantic -g -fsanitize=address,undefined -fno-omit-frame-pointer "$src/pulse_estimator.c" "$src/tests/test_estimator.c" -lm -o "$out/test_estimator_sanitized"
"$out/test_estimator_sanitized"
