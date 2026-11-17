#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out=${1:-"$root/.build/renders"}
blender=${BLENDER:-/Applications/Blender.app/Contents/MacOS/Blender}
source="$root/Mechanical/Render Source"
mkdir -p "$out/tmp" "$out/cache" "$out/user"
out=$(cd "$out" && pwd)
export TMPDIR="$out/tmp/" XDG_CACHE_HOME="$out/cache" BLENDER_USER_RESOURCES="$out/user"
export PYTHONDONTWRITEBYTECODE=1
cp "$source/component_geometry.json" "$out/"
python3 "$source/prepare.py" "$root" "$out"
if [ "${2:-}" = "--all" ]; then
    "$blender" --background --factory-startup --python-exit-code 1 --python "$source/render.py" -- \
        --output-dir "$out" --include-isolated
    python3 "$source/validate.py" "$out"
else
    "$blender" --background --factory-startup --python-exit-code 1 --python "$source/render.py" -- \
        --output-dir "$out" --only assembled_isometric.png
fi
