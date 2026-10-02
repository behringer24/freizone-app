#!/usr/bin/env bash
# Cross-compiles the Go core to static archives for iOS and drops them where
# the Xcode project links them from (ios/Flutter/FreizoneCore.xcconfig), so a
# normal `flutter build ios`/`flutter run` picks them up automatically.
#
# iOS apps can't load a loose shared library the way Android loads the .so
# from jniLibs, so the core is linked statically into the app binary and the
# Dart side finds its symbols with DynamicLibrary.process().
#
# Builds one arm64 archive per SDK: iphoneos (real devices, e.g. the iPad Air
# test device) and iphonesimulator (Apple Silicon simulators). Intel-Mac
# simulators (x86_64) are deliberately left out.
#
# KEEP IN STEP with IPHONEOS_DEPLOYMENT_TARGET in ios/Runner.xcodeproj: an
# archive built for a newer minimum than the app makes the linker warn and
# can crash on the older OS.

set -euo pipefail

MIN_IOS="16.0"
cd "$(dirname "$0")"
OUT_ROOT="../ios/Frameworks/FreizoneCore"

export CGO_ENABLED=1
export GOOS=ios
export GOARCH=arm64

# sdk name, clang target triple
targets=(
    "iphoneos arm64-apple-ios${MIN_IOS}"
    "iphonesimulator arm64-apple-ios${MIN_IOS}-simulator"
)

for t in "${targets[@]}"; do
    read -r sdk triple <<<"$t"
    sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
    export CC="$(xcrun --sdk "$sdk" -f clang) -isysroot $sysroot -target $triple"

    out_dir="$OUT_ROOT/$sdk"
    mkdir -p "$out_dir"
    go build -buildmode=c-archive -o "$out_dir/libfreizonecore.a" .
    # The generated header is only useful to C callers; Dart binds by name.
    rm -f "$out_dir/libfreizonecore.h"
    echo "Built $out_dir/libfreizonecore.a ($sdk, iOS $MIN_IOS+)"
done
