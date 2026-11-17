#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cli=${KICAD_CLI:-/Applications/KiCad/KiCad.app/Contents/MacOS/kicad-cli}
out=${1:-"$root/.build/mechanical/Rev E.1 Bare Board.step"}
mkdir -p "$(dirname -- "$out")"
"$cli" pcb export step --board-only --output "$out" "$root/CAD/FDS1010_Budget_E.kicad_pcb"
