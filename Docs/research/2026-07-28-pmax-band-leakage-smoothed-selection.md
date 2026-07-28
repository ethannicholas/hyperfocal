# PMax bloom: band leakage + unsupported selection wins (validated CPU candidates)

**Status (2026-07-28, second session — SHIPPED):** C2 re-anchored and
PASSING on the candidate; C5's attribution corrected by measurement (most of
it was never these mechanisms — see the addendum); a source-envelope
discipline landed that leaves the candidate better than or equal to baseline
on every C5 side; C1–C4 PASS; `retouch-probe` ALL PASS. After render review
the **defaults were flipped** (smoothed selection + envelope discipline on,
Burt expand always-on) — pre-flip defaults were re-verified bit-identical to
the be6585d snapshot (0.0 max diff), and the flipped defaults reproduce the
reviewed candidate renders bit-exactly. C5's absolute PASS remains open and
belongs to the hybrid-background renderer (regional commitment) — the
addendum records why no per-coefficient gating can reach it. Earlier
sections are kept as written; read them with the addendum's corrections.

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

## Addendum (2026-07-28, second session): C2 re-anchored, C5 re-attributed, envelope discipline landed

### C2: re-anchored, candidate PASSES, and the old anchor's failure is proven

The harness's C2 now judges against the registered sources with two one-sided
anchors (full-sweep `debug-register`, exposure-normalized to the frame
population, matched smoothing; anchors cached per canvas): **overshoot** of
the render's own top-1% vs the per-pixel ceiling's (max over ALL frames), and
**dimming** per pixel at the sharp-source anchor's own top-1% pixels (the
max-focus frame's rendition — the ground truth). Verdicts:

| | train | bottlebrush | fluorite |
|---|---|---|---|
| baseline (defaults) | **FAIL +2.23% over ceiling** | PASS | PASS |
| candidate | PASS +0.65% | PASS | PASS |

The baseline's train FAIL is the veil itself — fabricated highlight energy
the snapshot anchor scored as "+0.00%". The candidate's earlier "nominal
FAIL" dissolves exactly as predicted. Three instrument traps cost a wrong
reading each and are recorded in the harness docstring: exposure-normalizing
frames *to the render* imports the render's black-point offset into the
highlight comparison (+16% phantom overshoot on a dark stack); an
unnormalized ceiling rides a long sweep's exposure drift (7.3% across 82
frames); and judging dimming by own-top-slice aggregates penalizes debloom
for *shrinking the area* of its top slice (read −3.0% where the per-pixel
median moved −0.6% and crops showed crisp glints replacing bloomed blobs —
the sparkle crop evidence is beside the corpus).

### C5: the attribution in this doc was wrong

Per-mechanism decomposition on the harness's own tiles (high = >1.1×,
low = <0.7× the liveliest registered frame):

| config | pink_flower_2 hi/lo | bug hi/lo |
|---|---|---|
| baseline (defaults) | 5 / 33 | 43 / 0 |
| smoothed selection only | 6 / 31 | **35** / 0 |
| Burt expand only | 8 / 30 | **58** / 0 |
| both | 8 / 30 | 48 / 0 |

The C5 failures are ~90% **baseline** defects: pink_flower_2's deadening is
the near-black keep-darkest family (largely luminance — the dark garden
renders dark, so its texture measures dark), and bug's fabrication is plain
max-of-N. Smoothed selection *improves* bug's high side; the one real
mechanism regression is the Burt expand's faithful reconstruction of
selected noise (+15 tiles). "Gate the mechanisms" therefore cannot flip C5 —
its genuine fix is regional commitment (the hybrid-background renderer),
exactly as this doc's diagnostic decomposition already hinted.

### What landed: source-envelope discipline (CPU, part of smoothed selection)

Three pieces, engaged together with `smoothedSelection` (env kill-switches
`HYPERFOCAL_PMAX_ENV_CLAMP` / `HYPERFOCAL_PMAX_NB_TEX_VETO` for ablation):

- **Output-space envelope clamp** (`applyEnvelopeClamp`): in never-focused
  cells, the collapsed image's own finest-octave band energy (32 px cells)
  may not exceed the liveliest single source frame's. Output space is
  load-bearing: pre-collapse per-level bounding fails BOTH ways (mosaic
  bands from different frames partially cancel on reconstruction, so
  per-level parity collapses to 0.5–0.8× — 37/77 tiles pushed below the
  envelope — while per-cell bounds still sum above any single frame per
  tile). The octave sweep was measured: 1 octave 23 hi/0 lo, 3 octaves
  23 hi/10 lo — every scale past the finest trades fabrication for
  deadening, so it stays at one.
- **Per-pixel never-focused membership**: focus sweep ratio
  (focusMax0/focusMin0) against the N-anchored cut shared with the
  open-background clause (`neverFocusRatioCut`), judged per pixel and pooled
  as a fraction. Cell-pooled ratios compress until subjects read as
  background (measured p50 3.1 on a stack whose per-pixel focusing content
  runs into the thousands); absolute-energy membership misses energetic
  defocused foliage and would clamp in-focus low-energy backgrounds whose
  fusion gain (1.3–1.8×) is legitimate.
- **Near-black texture veto** (`nearBlackTextureVeto`): cells whose level-0
  band energy breathes with the sweep (amplitude ratio above an N-scaled
  cut; flat-backdrop noise 1.2–1.5×, live mottle 2.2–28×) leave the
  keep-darkest membership and fall to the clamped plain track. Two energy
  floors guard it: the min rendition must be above quantization junk (a
  crushed-black JPEG backdrop reads ratios of 10^5 on energies of 10^-6),
  and the max rendition must clear an absolute visibility floor (~0.6/255
  mean band amplitude — geometric middle of the measured black-backdrop /
  dark-garden gap).

**Result** (candidate = both mechanisms + discipline): bug **43/0 → 23/0**,
pink_flower_2 **5/33 → 6/30**; C1 PASS (now matching the sharp frame's
transition shape at every distance), C2 PASS ×3, C3/C4 PASS; the train veil
win is fully preserved (re-derived region metric: baseline +11.7, candidate
+1.0 with and without the discipline); sharpest-1% focus energy retained at
99.4%/98.8% vs the pre-clamp candidate (the mechanisms had gained 2–4%);
defaults bit-identical; probe ALL PASS. Visual crops (beside the corpus):
released garden mottle looks natural, clamped foliage softens gently toward
the sources, no mosaic artifacts.

### What C5 still needs — and it is the hybrid renderer's scope

- bug's remaining 23 high tiles are structured defocused foliage: bounding
  them further requires cross-frame coherence, not energy accounting (the
  measured dead ends above). Some may be C5 instrument conservatism — the
  (7,11) crop shows plausibly real multi-depth assembly of partially
  focusing fuzz at sweep 4.9×, well under C5's never-focused cut of 30 —
  worth revisiting when the hybrid work recalibrates the tile classifier.
- pink_flower_2's 30 low tiles are luminance-deadening (darkest base +
  keep-darkest family): only committing regions to a real frame's rendition
  fixes them honestly.

### Ship path, revised

The candidate is now better than or equal to baseline on every measured
axis (veil, C1–C4, both C5 sides on bug, C5-low on pink_flower_2; C5-high
there is 6 vs 5 tiles, the residual being the Burt expand on two mottle
tiles). **Decision taken 2026-07-28 after render review: the defaults are
flipped** — `Options.smoothedSelection` defaults true (the envelope
discipline rides with it) and the Burt expand is always-on
(`HYPERFOCAL_PMAX_EXPAND5=0` remains as the ablation switch); C5's absolute
PASS is carried as the hybrid renderer's acceptance bar. Remaining:
Metal/wgpu ports of the mechanisms + envelope discipline, ≥90 dB parity,
then the corpus snapshot regen ceremony — deliberately after the ports, so
it happens once on the shipping engine.
