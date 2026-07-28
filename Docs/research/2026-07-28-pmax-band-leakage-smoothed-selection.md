# PMax bloom: band leakage + unsupported selection wins (validated CPU candidates)

**Status (2026-07-28):** two CPU-only mechanisms implemented, measured, and
visually validated; defaults bit-identical to HEAD (verified 0.0 max diff);
`retouch-probe` ALL PASS. Not yet shipped: acceptance criteria C2/C5 need the
work recorded below before the defaults can flip. This doc is the handoff for
that work.

## The defect

On the train stack (private corpus), PMax paints a milky veil around blown
white text on the red car side and along the bright pantograph strut — bloom
from the defocused frames that the sharp source frame proves is not real
(the sharp frame renders clean red there). Measured as p99 luminance excess
over the sharp frame on red-background pixels around the "SBB CFF FFS" text:
**baseline +33.3** (8-bit scale). A reference render of the same stack
achieves +16.5, so the veil is not inherent to pyramid fusion.

This is the same fabrication family the debloom gate fights, but on a **lit,
smooth, colored surface** — a regime where the near-black membership correctly
stands down (the surface is never near-black), so the merge falls back to
track C (plain max-of-N), which fabricates. No existing gate claims this
regime; see "what remains" below.

## Mechanism 1: band leakage from the bilinear expand (`HYPERFOCAL_PMAX_EXPAND5=1`)

The CPU pyramid decimates corner-aligned (`coarse[m] ↔ fine[2m]`, 5-tap
`downKernel` blur then even-sample), but band computation and collapse
upsampled with **center-aligned bilinear** (`(x+0.5)·s−0.5`) — both a leakier
reconstruction low-pass than the proper Burt–Adelson expand and mismatched
with the decimation grid. Consequence: every band level keeps extra residual
low-frequency content, i.e. a defocused bright feature's glow contaminates
more levels at higher amplitude, and each contaminated level is another entry
point for max-selection to pick the veil.

The fix is the exact Burt expand (`upsampleBurtAt`): zero-stuff + 5-tap
`downKernel`, folded to per-parity taps — even fine samples read coarse
m−1/m/m+1 at (1/8, 6/8, 1/8), odd read m/m+1 at (1/2, 1/2); unity gain is
exact because the kernel's odd taps are exactly 1/4. Band computation and
collapse switch **together** (`CPUWorkspace.burtExpand`,
`collapse(_:burtExpand:)`) — either operator reconstructs exactly when used
for both, so this changes only what selection sees and how the fused pyramid
renders, never per-frame reconstruction identity.

Alone: veil +33.3 → **+24.0**.

## Mechanism 2: smoothed selection at every level (`--pmax-smooth-selection`, `Options.smoothedSelection`)

The level-0 grit blur exists because the max-selector can't tell focused
detail from isolated noise. The same failure repeats at coarse levels with
bloom in the noise role: the glow's smooth gradient wins scattered coarse
cells against a sharp frame whose energy is dense but locally lower. The
mechanism extends level 0's discipline to every band level: materialize the
level's band + energy (`levelBandEnergy`), blur the energy at the level's own
scale (same σ=1 kernel), winner-update on the smoothed energy
(`selectSmoothed`, `selectSmoothedFocusGated` — tracks B/bright pick by
Gaussian luminance, untouched). `HYPERFOCAL_PMAX_SMOOTH_SEL=0/1` overrides;
`HYPERFOCAL_PMAX_SMOOTH_SQ=1` swaps abs-sum energy for squared band luminance
(measured marginal: +23 vs +25 — ablation only).

Alone: +33.3 → **+25.4**, with Laplacian variance *up* 2–4% at every probe
region (isolated-noise wins removed).

## Combined result

**+19.5** — 83% of the gap to the reference closed. Top-1% luminance lands at
224.2, exactly the source frames' own top-1% ceiling (baseline: 226.3, above
it). Sharpness held; the one region whose lapvar dropped (274.6 → 258.8, the
"d's" keyline) visibly loses *ringing* (a greenish crunchy outline), not
detail. Both mechanisms force the CPU engine when enabled — a GPU path that
silently ignored them would measure the wrong configuration (same pattern as
despill).

Also measured: `--pmax-textured-base` (deviation-winner base instead of
darkest) fixes darkest-base's global −2.8 dim but worsens peak veil (+36) —
not a win standalone; kept flag-off for a follow-up that adds an entropy term.

Diagnostic decomposition worth keeping: forcing the debloom tracks everywhere
(near-black lo/hi overrides) reaches +18.9 — so the remaining ~3 points enter
through track C on the lit smooth surface, which is the hybrid-background
renderer's regime (frame-governed selection at every level), not something
these mechanisms can close.

## Acceptance harness (candidate = `HYPERFOCAL_PMAX_EXPAND5=1` + `--pmax-smooth-selection`)

C1 silhouette PASS · C3 no-trough PASS · C4 source-frame floor PASS (0.02%).

**C2 top-1% FAIL nominally** (train −2.27%, bottlebrush −1.60%, fluorite
−3.24% vs the saved snapshot) — **but the anchor looks wrong, with per-pixel
evidence**: registering five sweep-spanning fluorite frames onto each render
(`debug-register`, cached under `.build/pmax-acceptance/fluorite/reg-*`)
shows the *saved snapshot's* top-1% pixels exceed the per-pixel source-frame
ceiling on 35% of pixels (mean +0.064) vs the candidate's 21% (mean +0.045).
The "dimming" moves *toward* what the source frames contain — highlight-
flavored max-of-N fabrication being removed, the same species C5 catches on
textured backgrounds. **Next action: re-anchor C2 to the per-pixel source
ceiling (full-sweep registration, not 5 frames) instead of the snapshot,**
per the harness's own instrument-recalibration protocol, then re-judge.

**C5 envelope FAIL — the genuine blocker.** Two distinct failures:
- pink_flower_2: 30 tiles < 0.7× (smoothing deadens live bokeh mottle — the
  known failure the flatness gate exists for, now from a second mechanism);
- bug: 48 tiles > 1.1× (worse than baseline's count — the Burt collapse
  passes *selected* coarse noise through reconstruction more faithfully than
  bilinear did).
Both point the same way: these mechanisms need **texture-aware engagement
gating** (the be6585d flatness-gate pattern) so they act only where their
scene model holds. That work merges naturally with the hybrid-background
renderer item, which owns the same regime split.

## Ship path (in order)

1. Re-anchor C2 (above); re-run the harness on the candidate.
2. Engagement gating for C5 (both sides); re-run.
3. Flip `Options` defaults (smoothedSelection true; expand5 promoted from env
   to always-on or an Options field — decide when gating lands).
4. Port both mechanisms to Metal (`GPUPyramid`) and wgpu (`WgpuPyramid`);
   restore ≥90 dB engine parity; `debug-wgpu` gates.
5. Regenerate corpus snapshots with the README ceremony (never to hide a
   regression; this one is motivated).
6. Decide UI exposure (probably none — one fewer knob; if exposed, both
   shells + catalog translations, per the dual-UI and localization
   invariants).

## Reproduction

```sh
# candidate render (CPU forced automatically)
HYPERFOCAL_PMAX_EXPAND5=1 .build/debug/hyperfocal-cli fuse -m pmax \
    --pmax-smooth-selection <frames…> -o out.tif
# acceptance harness
HYPERFOCAL_PMAX_EXPAND5=1 HF_FUSE_ARGS="--pmax-smooth-selection" \
    /tmp/hf-score/bin/python "…/Sample Stacks/pmax-acceptance.py" --suffix -exp5smooth
```

Veil metric, comparison renders, and per-stack numbers live beside the
private corpus (train folder notes), not in this repo, per the corpus
README's scoping rules.
