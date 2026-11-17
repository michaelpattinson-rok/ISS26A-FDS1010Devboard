#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out=${1:-"$root/.build/analog"}
source="$root/Docs/Analysis"
mkdir -p "$out/Source Evidence" "$out/Independent Validation"
cp "$root/CAD/Circuit.json" "$out/Source Evidence/Circuit.json"
cp "$source/analog_analysis.py" "$out/"
cp "$source/Independent Validation/"*.py "$out/Independent Validation/"
python3 "$out/Independent Validation/independent_transfer.py"
python3 "$out/Independent Validation/loop_units_crosscheck.py"
python3 "$out/analog_analysis.py"
