# Cross-compiles the Go core to JNI-loadable shared libraries for Android and
# drops them straight into the Flutter project's jniLibs, so a normal
# `flutter build`/`flutter run` picks them up automatically.
#
# Builds arm64-v8a (real devices, e.g. the Pixel test phone) and x86_64 (the
# common desktop emulator image). Add more ABIs to $targets below if needed
# (see docs/PROTOCOL note on deferred ABIs).

$ErrorActionPreference = "Stop"

$ndkRoot = "$env:ANDROID_HOME\ndk"
if (-not (Test-Path $ndkRoot)) {
    Write-Error "Android NDK not found under $ndkRoot -- is ANDROID_HOME set?"
    exit 1
}

$ndkVersion = (Get-ChildItem $ndkRoot | Sort-Object Name -Descending | Select-Object -First 1).Name
$toolchain = "$ndkRoot\$ndkVersion\toolchains\llvm\prebuilt\windows-x86_64\bin"

# One entry per Android ABI: the jniLibs folder name, the Go GOARCH, and the
# NDK clang wrapper that targets it (min API level 21).
#
# KEEP IN STEP with abiFilters in android/app/build.gradle.kts. Flutter emits a
# split per ABI it knows about, whether or not there is a core for it, so an ABI
# missing here but allowed there ships an app that installs and dies on its
# first FFI call. That is exactly what happened with armeabi-v7a: every other
# native library was in the split, this one was not, and nobody noticed because
# no test device is 32-bit.
$targets = @(
    @{ Abi = "arm64-v8a"; GoArch = "arm64"; Clang = "aarch64-linux-android21-clang.cmd" },
    @{ Abi = "x86_64";    GoArch = "amd64"; Clang = "x86_64-linux-android21-clang.cmd" }
)

$env:CGO_ENABLED = "1"
$env:GOOS = "android"

Push-Location $PSScriptRoot
try {
    foreach ($t in $targets) {
        $clang = "$toolchain\$($t.Clang)"
        if (-not (Test-Path $clang)) {
            Write-Error "NDK clang not found at $clang"
            exit 1
        }
        $outDir = "$PSScriptRoot\..\android\app\src\main\jniLibs\$($t.Abi)"
        New-Item -ItemType Directory -Force -Path $outDir | Out-Null

        $env:GOARCH = $t.GoArch
        $env:CC = $clang
        go build -buildmode=c-shared -o "$outDir\libfreizonecore.so" .
        Write-Output "Built $outDir\libfreizonecore.so (NDK $ndkVersion, $($t.Abi))"
    }
} finally {
    Pop-Location
}
