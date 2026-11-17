#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out=${1:-"$root/.build/app"}
mkdir -p "$out"
out=$(cd "$out" && pwd)
mkdir -p "$out/tmp" "$out/home"
export TMPDIR="$out/tmp/" CFFIXED_USER_HOME="$out/home"
xcodebuild -project "$root/Software/Signal Bench/Signal Bench.xcodeproj" \
    -scheme 'Signal Bench' -configuration Release -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$out/DerivedData" -disableAutomaticPackageResolution \
    CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS=-disable-sandbox build
app="$out/DerivedData/Build/Products/Release/Signal Bench.app"
xattr -cr "$app"
codesign --force --sign - --entitlements \
    "$root/Software/Signal Bench/Signal Bench/Signal Bench.entitlements" "$app"
codesign --verify --deep --strict "$app"
printf '%s\n' "$app"
