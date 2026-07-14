# Hyperfocal Roadmap

Working list toward public release, in priority order. Written to be
self-contained: each item says what, why, where in the code, and what "done"
looks like, so any future session (or contributor) can pick one up cold.
Completed work is removed from this file — git history and the README are
the record of what shipped.

**State as of 2026-07-07:** feature work through workflow parity is done —
sandboxed app with security-scoped bookmarks, licensing/notices, retouch
eraser, bad-frame exclude-and-continue, multi-stack projects (folder
recursion, stack tree, fuse queue, export-all; project format v3 with a v2
reader — CLI `batch` remains for headless runs), Display P3 working space
with converting exports, Lanczos-3 warp resampling, and GPU pyramid (PMax)
fusion. Regression gates:
`swift build && .build/debug/retouch-probe <synth frames…>` must print
`probe: ALL PASS`, and `hyperfocal-cli synth` baselines (default params) are
**plane ≈ 38.7 dB dmap / 38.3 pmax** vs truth, **object ≈ 41.3 unslabbed /
40.3 slabbed** (as of the quality campaign through median-consensus
blending; defaults sharpness σ = 10 / guided radius 128 / median radius
20, 2026-07-13). CPU↔GPU parity: ≥ 90 dB both methods (measured ~114
dmap / 106 pmax on the synth plane — the guided regularizer's shared
grid stage removed the old threshold-flip caveat that had dmap at
≥ 65) — re-check before trusting any algorithm change.

---

## Release blockers

### 1. Bug fixes & minor features

(Empty — new small items land here.)

---

## Engine performance

### 3. PMax at 45 MP — remaining levers are GPU-side, not decode

Clean-machine numbers (2026-07-12, real 50-frame 45 MP NEF stack, local
SSD, idle 8-core/16 GB M-series; earlier same-day measurements were
inflated 2–3× by background load — benchmark only on an idle machine):
registration ≈ 25–30 s (app caches it after first fuse), aligned PMax
fusion 36 s (was 66 s before the GPU warp), unaligned decode+pyramid
24 s. Decode is *not* the bottleneck on this hardware: prefetch width 3
vs 4 measures identical (±0.5%), and 6 is reliably ~40% worse (memory
pressure on 16 GB) — `FramePrefetcher.defaultLookahead` now scales with
cores/RAM and caps there. Toward the original < 15 s aspiration the
remaining levers are GPU-side: the ~12 s aligned-vs-unaligned delta
(per-frame full-res upload + warp dispatch) and the pyramid pass itself
(~24 s) — profile before believing either. Reading straight off the
camera card costs only ~10% extra when idle (26 vs 24 s unaligned,
cold cache; prefetch width irrelevant there too) — the earlier "card
doubles everything" observation was background-load contention, so a
tutorial note is only worth it as "don't fuse while the machine is
busy".

### 3a. Research-informed fusion follow-ons

From the 2026-07-12 deep-research pass — **full findings, evidence
quotes, source list, refuted claims, and open questions are in
`Docs/research/2026-07-12-focus-stacking-research.md`** (with raw
workflow outputs alongside); consult it before revisiting any of this.
Key sources: Pertuz et al. Pattern Recognition 2013 [the 36-operator SFF
benchmark]; Jeon et al. IEEE TIP 2019 [Ring Difference Filter]; Ali et al.
Pattern Recognition 2021 + CVIU 2022 [guided-filter depth refinement];
Moeller et al. IEEE TIP 2015 [variational DfF]; zerenesystems.com and
heliconsoft.com primary docs:

Context: the guided-filter depth regularizer (was item 3b here) shipped
2026-07-12 — confidence-weighted adaptive-ε WGIF at the sharpness grid,
guided by mean stack luminance, with a confidence-preservation blend
(`DepthRegularize.swift`; ablation env switches
`HYPERFOCAL_GUIDED_NO_TIER2` / `_NO_TIER2_MASK` / `_FIXED_EPS`). It
killed the wedge ghosts and rim band on the 163-frame mineral stack
(in `~/Desktop/Sample Stack JPEG` while it lasts; regenerate: fluorite
specimen on marble, subject sharp mid-stack, tail focused past it) and
unblocked the estimation-window win: σ default is now 10 (swept
{3, 6, 10, 16}: no radial rays at any σ with the guided path; 16 starts
to bloat the silhouette). Remaining follow-ons, each judged against the
specular-bokeh stack:

- **Focus-measure upgrades to evaluate**: Ring Difference Filter kernel
  (local accuracy + non-local noise robustness, public code), multi-scale
  dilated Laplacian; variance or Tenengrad as a noise-robust
  *complementary gate* (statistics-based measures are the most
  noise-robust family; Laplacian is the least, and degrades above ~30%
  saturation — i.e. on speculars).
- **Render**: energy-weighted averaging *only inside low-confidence
  regions* (as a global strategy it sacrifices sharpness — Helicon
  Method A); reserve pyramid fusion for flagged overlap/discontinuity
  regions (the automated version of the vendor-documented "DMap base
  retouched from PMax" hybrid — which our retouch eraser/PMax-layer
  workflow already mirrors manually).
- **Stronger regularization, only if artifacts demand it**: aggregate the
  focus *cost volume* before argmax (RDF-style, or separable 3D-WLS per
  Ali/Pruks/Mahmood 2019 — tridiagonal 1-D solves, plausibly GPU-feasible
  at grid resolution). "Joint estimation is markedly better than
  compute-then-smooth" was REFUTED in verification — upgrade stages,
  don't restructure. Known bounded behavior of the shipped stage: where
  the guide is flat across a confidence rim, ramps meet plateaus with a
  seed-side bias (probe bounds it < 4 frames on the synthetic ramp); a
  2-pass iteration is the flagged remedy if a real stack ever shows it.
- **Fundamental limit worth remembering**: at depth discontinuities the
  correct pixels may exist in NO source frame (defocused foreground
  occludes the background everywhere) — vendors document this as
  unfixable by any per-pixel selection; perfection is a non-goal, the
  retouch workflow is the answer of record.

Open (unresearched despite two passes): fusion-quality metrics
(Q_AB/F, MI, SSIM-variants) for the regression suite, and Core
ML-portable 2020+ fusion/DfF networks — needs a dedicated metrics pass
if wanted; PSNR-vs-synthetic-truth remains our gate meanwhile.

Gates: synth baselines in the header, probe ALL PASS, CPU/GPU parity,
and the sample stack's three regions (shadow under the rim, substrate
above the specimen, silhouette band) eyeballed against Helicon's result.

### 4. Session-scoped slab cache

Each fuse deletes the previous slab directory (`AppModel.installSlabs`), so
a *saved* project's retouch sources die when the user later fuses anything
else. Options: refcount directories by the projects that reference them,
copy slabs into the `.hyperfocal` bundle on explicit save (~0.5 GB), or
lazily re-fuse slabs on demand from `framePaths` + `transforms`
(deterministic; probably best).

---

## Community candy (post-1.0 or launch-adjacent)

### 5. Synthetic stereo pairs + rocking animations

All the hard input exists already:
`DMapFusion.Output.depth` is a full-resolution regularized depth plane.
Reproject the fused image with per-pixel horizontal disparity ∝ depth
(± for left/right eye), jump-flood or inpaint the disocclusion slivers
(the old `nearestSeedFill` jump-flood, removed 2026-07-12, is in git
history), and export: side-by-side stereo PNG,
crossed-eye pair, and a 2–4 s rocking MP4/GIF (AVFoundation writer).
UI: an "Animate…" button next to Export once a result exists.

### 6. Smaller parity items (grab-bag, roughly ordered)

- **Frame-order sanity:** frames now sort by EXIF capture time by default
  (`StackSplitter.ordered`, Loading setting toggles back to filename), but
  when the two orderings *disagree* nothing tells the user — warn on
  mismatch so a shuffled or interleaved load (which fuses to garbage
  silently) gets caught. Undated stacks fall back to name order with no
  signal that capture ordering wasn't available.
- **ETA in the progress card:** stages already report fractions
  (`FusionProgress`); time the current stage and extrapolate.
- **Slab highlight:** during slabbed retouch the Stack list (which lists
  original frames) highlights frame sources fine — original frames are in
  the source list since 2026-07-06 — but can't highlight an active *slab*
  source; show a "Slab 3/6 (frames 23–36)" chip for those.
- **Per-channel exposure gains:** current flicker normalization is a single
  luminance gain per frame (`DMapFusion.renderGains`); LED-lit stacks can
  flicker per-channel (WB wobble). Same machinery, 3 gains instead of 1;
  keep the geometric-mean anchor per channel.
- **Cancel PMax generation:** currently there's no way to stop a PMax
  generation once you've started it.

---

## Documentation (parallel track, pre-release)

Site source lives in `Site/` — hand-written static HTML/CSS, no build step;
live at https://ethannicholas.com/hyperfocal (upload via the publish
workflow after changes). The overview (philosophy vs Zerene/Helicon: free,
native, open), tutorial (shoot → import → fuse → depth map → noise floor →
tone → retouch → export, with a downloadable synthetic sample stack), and
reference (all app tooltips verbatim + shortcuts + CLI flags) pages exist.
Remaining:

- Replace the synthetic-stack imagery with a real stack (Ethan's mineral
  macros): hero screenshot, retouch screenshot, fused/depth pair, and
  ideally the downloadable sample stack itself.
- CONTRIBUTING.md: build instructions exist in README (SwiftPM + XcodeGen);
  add probe/synth-regression expectations for PRs.