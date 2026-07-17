# Cross-compiles the Go core to a JNI-loadable shared library for Android
# arm64 (the only ABI needed for now -- see docs/PROTOCOL note on deferred
# ABIs) and drops it directly into the Flutter project's jniLibs so a
# normal `flutter build`/`flutter run` picks it up automatically.

$ErrorActionPreference = "Stop"

$ndkRoot = "$env:ANDROID_HOME\ndk"
if (-not (Test-Path $ndkRoot)) {
    Write-Error "Android NDK not found under $ndkRoot -- is ANDROID_HOME set?"
    exit 1
}

$ndkVersion = (Get-ChildItem $ndkRoot | Sort-Object Name -Descending | Select-Object -First 1).Name
$clang = "$ndkRoot\$ndkVersion\toolchains\llvm\prebuilt\windows-x86_64\bin\aarch64-linux-android21-clang.cmd"
if (-not (Test-Path $clang)) {
    Write-Error "NDK clang not found at $clang"
    exit 1
}

$outDir = "$PSScriptRoot\..\android\app\src\main\jniLibs\arm64-v8a"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$env:CGO_ENABLED = "1"
$env:GOOS = "android"
$env:GOARCH = "arm64"
$env:CC = $clang

Push-Location $PSScriptRoot
try {
    go build -buildmode=c-shared -o "$outDir\libfreizonecore.so" .
    Write-Output "Built $outDir\libfreizonecore.so (NDK $ndkVersion)"
} finally {
    Pop-Location
}
