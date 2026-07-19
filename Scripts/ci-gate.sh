#!/bin/bash
# The CI regression gate: release build, synth→fuse→compare PSNR floors,
# and the retouch probe. CI runs exactly this script (see
# .github/workflows/ci.yml); run it locally to reproduce a CI result.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== build (release)"
swift build -c release
BIN=.build/release/hyperfocal-cli

WORK="${TMPDIR:-/tmp}/hyperfocal-ci-gate"
rm -rf "$WORK"
mkdir -p "$WORK"

# PSNR floors are platform-calibrated just under each platform's
# measured baseline (plane scene, default synth params, P3 export to
# match the ground truth): Linux measures 39.1 dmap / 38.6 pmax
# (aarch64, 2026-07-19); macOS 38.71 dmap / 38.26 pmax (the ROADMAP
# baselines) — a shared 38.3 pmax floor sat above the macOS baseline
# and failed on noise alone.
if [ "$(uname)" = Darwin ]; then PMAX_FLOOR=38.1; else PMAX_FLOOR=38.3; fi
echo "== synth PSNR gates"
"$BIN" synth -o "$WORK/synth"

gate() { # method floor
    local method=$1 floor=$2 line psnr
    "$BIN" fuse "$WORK"/synth/frame_*.tif -o "$WORK/out-$method.tif" \
        --method "$method" --color-space p3
    line=$("$BIN" compare "$WORK/out-$method.tif" "$WORK/synth/ground_truth.tif")
    psnr=$(echo "$line" | awk '{print $2}')
    echo "$method: $line (floor $floor)"
    awk -v p="$psnr" -v f="$floor" 'BEGIN { exit !(p >= f) }' || {
        echo "== CI GATE FAILED: $method PSNR $psnr dB < floor $floor dB"
        exit 1
    }
}
gate dmap 38.7
gate pmax "$PMAX_FLOOR"

# DNG round-trip: exporting through our DNG writer and decoding back (LibRaw
# on Linux, CIRAW on macOS) must reproduce the TIFF render. Guards the raw
# color chain — linear-gamma decode, declared-white-level scaling,
# embedded-matrix preference. Floors are platform-calibrated because the
# decoder differs by design (divergence documented in the plan): LibRaw
# reproduces our linear DNGs at ≈93 dB (Linux/aarch64, 2026-07-19); CIRAW
# renders them through Apple's own pipeline and has always sat at ≈48 dB
# (measured identically at 3bc4b65, before the 2026-07-19 RAW work — a
# tripwire against macOS-side drift, not a fidelity claim).
if [ "$(uname)" = Darwin ]; then DNG_FLOOR=45; else DNG_FLOOR=60; fi
echo "== DNG round-trip gate"
"$BIN" fuse "$WORK"/synth/frame_*.tif -o "$WORK/rt.dng" --color-space p3
rtline=$("$BIN" compare "$WORK/rt.dng" "$WORK/out-dmap.tif")
rtpsnr=$(echo "$rtline" | awk '{print $2}')
echo "dng round-trip: $rtline (floor $DNG_FLOOR)"
awk -v p="$rtpsnr" -v f="$DNG_FLOOR" 'BEGIN { exit !(p >= f) }' || {
    echo "== CI GATE FAILED: DNG round-trip PSNR $rtpsnr dB < floor $DNG_FLOOR dB"
    exit 1
}

# The probe target is macOS-only (Package.swift: it drives AppKit-side
# checks; the Linux gate is the synth→fuse→compare path above).
if [ "$(uname)" = Darwin ]; then
    echo "== retouch probe"
    "$BIN" synth -o "$WORK/probe-synth" \
        --frames 15 --max-blur 6 --breathing 0.02 --jitter 3
    .build/release/retouch-probe "$WORK"/probe-synth/frame_*.tif
fi

echo "== CI GATE PASSED"
