# Builds the Go core as a shared library for the *development host*, so
# `flutter test` can reach it. Nothing ships from here -- build_android.ps1
# produces what the app actually loads on a device.
#
# Why this exists: FreizoneCoreBindings loads libfreizonecore.so on Android and
# otherwise falls back to DynamicLibrary.process(), which finds nothing in a
# test process. That is why lib/state/ -- the whole protocol orchestration --
# has no host test coverage today: every test touching it would need the core.
# With this library present, a test can pass its path to FreizoneCore and
# exercise the real thing (see test/receive_path_conformance_test.dart, SRV-23).
#
# Needs a C toolchain, because the core is cgo. On Windows that is mingw-w64:
#   winget install --id BrechtSanders.WinLibs.POSIX.UCRT --source winget
# The Android NDK's clang cannot stand in -- it only targets Android.

$ErrorActionPreference = "Stop"

# WinLibs via winget lands here and does not reach this session's PATH; fall
# back to whatever gcc is already on PATH so a differently-installed toolchain
# (MSYS2, chocolatey, a Linux host) works unchanged.
$wingetMingw = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Packages\BrechtSanders.WinLibs.POSIX.UCRT_Microsoft.Winget.Source_8wekyb3d8bbwe\mingw64\bin"
if (Test-Path (Join-Path $wingetMingw "gcc.exe")) {
    $env:Path = "$wingetMingw;$env:Path"
}

$gcc = Get-Command gcc -ErrorAction SilentlyContinue
if (-not $gcc) {
    Write-Error "No C compiler found. cgo needs one -- see the note at the top of this file."
    exit 1
}

$env:CGO_ENABLED = "1"
$env:CC = $gcc.Source

Push-Location $PSScriptRoot
try {
    # Host platform, deliberately: this is for running tests where they are
    # written, not for cross-building anything shippable.
    Remove-Item Env:GOOS -ErrorAction SilentlyContinue
    Remove-Item Env:GOARCH -ErrorAction SilentlyContinue

    $name = if ($IsMacOS) { "libfreizonecore.dylib" } elseif ($IsLinux) { "libfreizonecore.so" } else { "freizonecore.dll" }
    $out = Join-Path $PSScriptRoot $name

    go build -buildmode=c-shared -o $out .
    if (-not (Test-Path $out)) {
        Write-Error "Build reported success but $out is missing"
        exit 1
    }

    $mb = [math]::Round((Get-Item $out).Length / 1MB, 2)
    Write-Output "Built $out ($mb MB, $($gcc.Source))"
    Write-Output "Run the host tests with: flutter test"
} finally {
    Pop-Location
}
