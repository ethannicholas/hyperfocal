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
# match the ground truth): Linux measured 39.1 dmap / 38.6 pmax
# (aarch64, 2026-07-19); macOS 38.41 dmap / 38.26 pmax — a shared 38.3
# pmax floor sat above the macOS baseline
# and failed on noise alone.
#
# The dmap floor dropped from 38.7 to 38.2 when the focus measure gained
# its pre-Laplacian denoise (Options.focusPreSigma, 2026-07-26). The synth
# plane is *noiseless*, so denoising can only cost precision there — it is
# the one input class the change cannot help, and it gave up 0.31 dB.
# Real stacks are the opposite case: across the nine reference sample
# stacks the same change lifted mean sharpness 86.8% -> 94.2% of best
# achievable, and took the worst stack from 59% to 101%. Do not "recover"
# this 0.3 dB by shrinking focusPreSigma without re-running that
# comparison. A synth scene with sensor noise would gate this honestly.
if [ "$(uname)" = Darwin ]; then PMAX_FLOOR=38.1; else PMAX_FLOOR=38.3; fi
echo "== synth PSNR gates"
"$BIN" synth -o "$WORK/synth"

gate() { # method floor [stackdir [label]]
    # Separate statements on purpose: `local` declares every name before it
    # assigns any, so a default referring to an earlier one on the same line
    # ("label=${4:-$method}") reads it as unset and dies under `set -u`.
    local method=$1 floor=$2 dir=${3:-$WORK/synth}
    local label=${4:-$method} line psnr
    "$BIN" fuse "$dir"/frame_*.tif -o "$WORK/out-$label.tif" \
        --method "$method" --color-space p3
    line=$("$BIN" compare "$WORK/out-$label.tif" "$dir/ground_truth.tif")
    psnr=$(echo "$line" | awk '{print $2}')
    echo "$label: $line (floor $floor)"
    awk -v p="$psnr" -v f="$floor" 'BEGIN { exit !(p >= f) }' || {
        echo "== CI GATE FAILED: $label PSNR $psnr dB < floor $floor dB"
        exit 1
    }
}
gate dmap 38.2
gate pmax "$PMAX_FLOOR"

report() { # method stackdir label — fuse + compare, floor not yet calibrated
    local method=$1 dir=$2 label=$3
    "$BIN" fuse "$dir"/frame_*.tif -o "$WORK/out-$label.tif" \
        --method "$method" --color-space p3
    echo "$label: $("$BIN" compare "$WORK/out-$label.tif" "$dir/ground_truth.tif") (UNCALIBRATED — not gated)"
}

# The same plane WITH sensor noise. The clean plane is the one input
# class a noise-robustness change cannot help (see the focusPreSigma
# note above: it COST 0.31 dB here while lifting every real stack), so
# gating only the clean scene punishes exactly the changes real stacks
# reward. The noisy plane gates that direction honestly.
"$BIN" synth -o "$WORK/synth-noisy" --noise 0.005
if [ "$(uname)" = Darwin ]; then
    # Measured macOS baselines 37.81 dmap / 37.57 pmax (bit-stable).
    gate dmap 37.3 "$WORK/synth-noisy" noisy-dmap
    gate pmax 37.1 "$WORK/synth-noisy" noisy-pmax
else
    report dmap "$WORK/synth-noisy" noisy-dmap
    report pmax "$WORK/synth-noisy" noisy-pmax
fi

# Scene gates — the bias-class fixtures. The plane scene cannot express
# any dark-backdrop, bright-field, or never-focused failure, so each
# class gets its own synthetic scene and floor (macOS floors sit ~0.5 dB
# under baselines that are bit-stable across reps on the calibration
# machine; other platforms report until a session there calibrates,
# same convention as the registration-scale gate below):
#  - object: bright subject over a near-black backdrop — the halo /
#    defocus-spill class.
#  - brightObject (+2% flicker): dark subject over a near-white sweep —
#    the sign-inverted-membership class. Before PMax normalized exposure
#    (bias-audit A0) its number sat at 35.58, ~11 dB under DMap's —
#    darkest-frame selection read the flicker as signal; normalization
#    lifted it to 40.18 and the floor fences the normalized baseline.
#    The remaining gap to DMap (~6.6 dB) is the un-remediated rest of
#    the family (darkest-base and friends), so later remediations
#    should raise this number again — re-raise the floor when they do.
#  - foreground (sensor noise, no breathing/jitter): a lit near layer
#    the sweep never reaches — the never-focused-foreground class.
#    Noise is load-bearing: it floors the energy ratios the way real
#    sensors do (a noiseless defocused layer reads either flat or
#    steeply "focusing", never the measured gentle decline). Breathing
#    and jitter are off so the truth's pixel-scale detail stays
#    achievable and fusion selection, not alignment, is what's scored.
echo "== scene gates (bias-class fixtures)"
"$BIN" synth -o "$WORK/synth-object" --scene object
"$BIN" synth -o "$WORK/synth-bright" --scene brightObject --flicker 0.02
"$BIN" synth -o "$WORK/synth-fg" --scene foreground --noise 0.002 \
    --breathing 0 --jitter 0

if [ "$(uname)" = Darwin ]; then
    gate dmap 33.5 "$WORK/synth-object" object-dmap
    gate pmax 33.2 "$WORK/synth-object" object-pmax
    gate dmap 46.3 "$WORK/synth-bright" bright-dmap
    gate pmax 39.7 "$WORK/synth-bright" bright-pmax
    gate dmap 36.4 "$WORK/synth-fg" fg-dmap
else
    report dmap "$WORK/synth-object" object-dmap
    report pmax "$WORK/synth-object" object-pmax
    report dmap "$WORK/synth-bright" bright-dmap
    report pmax "$WORK/synth-bright" bright-pmax
    report dmap "$WORK/synth-fg" fg-dmap
fi

# Mechanism fences on the foreground scene. The global PSNR cannot see
# a silently disengaging regional mechanism — the band's improvement is
# diluted ~8:1 by the sharp plane around it — so the fences are
# behavioral and differential:
#  - PMax governance tier L must engage on the class fixture and commit
#    the band to the edge frame (asserted from the fuse log; the same
#    shared governBackground decides on every engine).
#  - DMap must render the band from a committed frame: with the
#    committed tiers ablated this scene measures 36.92 -> 36.07 (macOS,
#    bit-stable), so default-minus-ablated must stay >= 0.4 dB.
"$BIN" fuse "$WORK"/synth-fg/frame_*.tif -o "$WORK/out-fg-pmax.tif" \
    --method pmax --color-space p3 -v > "$WORK/fg-pmax.log" 2>&1
fgpmax_line=$("$BIN" compare "$WORK/out-fg-pmax.tif" "$WORK/synth-fg/ground_truth.tif")
fgpmax=$(echo "$fgpmax_line" | awk '{print $2}')
HYPERFOCAL_GUIDED_NO_TIER2=1 HYPERFOCAL_GUIDED_NO_REGIONAL=1 \
    "$BIN" fuse "$WORK"/synth-fg/frame_*.tif -o "$WORK/out-fg-dmap-abl.tif" \
    --method dmap --color-space p3
fgdmap=$("$BIN" compare "$WORK/out-fg-dmap.tif" "$WORK/synth-fg/ground_truth.tif" | awk '{print $2}')
fgabl=$("$BIN" compare "$WORK/out-fg-dmap-abl.tif" "$WORK/synth-fg/ground_truth.tif" | awk '{print $2}')
echo "fg-pmax: $fgpmax_line"
echo "fg-dmap committed $fgdmap dB vs ablated $fgabl dB"
if [ "$(uname)" = Darwin ]; then
    grep -q "lit component ([0-9]* cells) committed to frame 1 " "$WORK/fg-pmax.log" || {
        echo "== CI GATE FAILED: PMax tier L did not commit the never-focused band to its edge frame"
        grep -i "gov" "$WORK/fg-pmax.log" || true
        exit 1
    }
    awk -v p="$fgpmax" 'BEGIN { exit !(p >= 36.8) }' || {
        echo "== CI GATE FAILED: fg-pmax PSNR $fgpmax dB < floor 36.8 dB"
        exit 1
    }
    awk -v d="$fgdmap" -v a="$fgabl" 'BEGIN { exit !(d - a >= 0.4) }' || {
        echo "== CI GATE FAILED: DMap regional commitment gains only $fgdmap - $fgabl dB on the never-focused band (>= 0.4 required)"
        exit 1
    }
else
    echo "fg mechanism fences: UNCALIBRATED — not gated (calibrate on this platform and gate)"
fi

# Registration-scale gate. The stack above is 900 px on its longest side,
# which sits BELOW the registration decode bound (max(1000, longest/5)) —
# so it takes the full-decode path on every platform and is structurally
# blind to anything that changes what the registrar sees at scale. That
# blind spot is not hypothetical: reducing Vision's registration input to
# the bound cost 6-7 dB against ground truth (2026-08-11) and the gate
# above did not move by a thousandth of a dB.
#
# 4240x2832 is the cheapest shape that clears the bound (~10 s for the
# whole section). Anything that degrades registration accuracy at real
# frame sizes shows up here and nowhere else in this script.
echo "== registration-scale gate (frames above the registration bound)"
"$BIN" synth -o "$WORK/synth-big" --width 4240 --height 2832 --frames 17
if [ "$(uname)" = Darwin ]; then
    # Measured on the M5 Max, 2026-08-11: dmap 51.92, pmax 50.93 (bit-stable
    # across reps). Floors sit ~2 dB under, which still leaves ~4 dB of
    # separation from the 45.60 the regression above produced.
    gate dmap 50.0 "$WORK/synth-big" dmap-big
    gate pmax 49.0 "$WORK/synth-big" pmax-big
else
    # NOT YET CALIBRATED off Apple, and deliberately not given a guessed
    # floor: registration is OpenCV SIFT there, not Vision, and the two have
    # opposite scale sensitivity (that is precisely the error that produced
    # the dead end above — reasoning from SIFT's measured scale-tolerance to
    # Vision's). A floor loose enough to be safe would be too loose to catch
    # anything, which is worse than an honest gap. First Linux/Windows
    # session: run this, read the two numbers, and paste them in ~2 dB down.
    "$BIN" fuse "$WORK"/synth-big/frame_*.tif -o "$WORK/out-dmap-big.tif" \
        --method dmap --color-space p3
    "$BIN" fuse "$WORK"/synth-big/frame_*.tif -o "$WORK/out-pmax-big.tif" \
        --method pmax --color-space p3
    echo "dmap-big: $("$BIN" compare "$WORK/out-dmap-big.tif" "$WORK/synth-big/ground_truth.tif") (UNCALIBRATED — not gated)"
    echo "pmax-big: $("$BIN" compare "$WORK/out-pmax-big.tif" "$WORK/synth-big/ground_truth.tif") (UNCALIBRATED — not gated)"
    echo "== NOTE: registration-scale floors need calibrating on this platform (see Scripts/ci-gate.sh)"
fi

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

echo "== string catalog"
Scripts/check-xcstrings.sh

echo "== translation coverage"
"$(Scripts/python-interpreter.sh)" Scripts/check-translations.py

echo "== per-platform notices"
"$(Scripts/python-interpreter.sh)" Scripts/gen-notices.py --check

# The shipped wgpu DLL statically links ~140 Rust crates whose attribution is
# generated, not hand-written. This check is offline — it only asserts the
# bundle was generated for the tag Scripts/fetch-wgpu.sh currently pins, which
# is what a wgpu bump would otherwise leave stale.
echo "== wgpu third-party notices"
"$(Scripts/python-interpreter.sh)" Scripts/gen-wgpu-notices.py --check

echo "== CI GATE PASSED"
