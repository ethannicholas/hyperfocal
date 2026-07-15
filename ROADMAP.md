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
**plane ≈ 38.7 dB dmap / 38.3 pmax** vs truth, **object ≈ 41.3** (as of
the quality campaign through median-consensus
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

### 3. Fusion at 45 MP is decode-bound — remaining levers

Measured 2026-07-15 (50-frame 45 MP NEF stack, `pyramid phases:` line in
-v output; interleaved A/B under moderate background load — capture
idle-machine numbers when convenient): the aligned GPU PMax fuse spends
**~80% of its wall clock waiting on RAW decode** (decode-wait 44 s vs
GPU 7.4 s incl. warps, upload 3 s on a loaded machine; ~19–27 s decode
in quieter windows). The earlier "levers are GPU-side" framing was
wrong: the pyramid pass and the upload+warp delta together are ~10 s,
not 24+12.

The self-inflicted part is fixed: Apple's RAW engine is internally
parallel (GPU), so the prefetcher's 4–8 concurrent CIRAWFilter decodes
only contended — 4-way ran ~65% slower per frame than serial; 2-way
ties serial. `FramePrefetcher` now separates window depth (memory)
from decode workers, and GPU paths use `FramePrefetcher.workers(for:)`
(2 for RAW, full for CPU-bound TIFF/JPEG). Interleaved A/B: workers=2
beat workers=4 in both rounds (32.1 vs 34.9 s, 23.7 vs 28.5 s,
unaligned PMax). `HYPERFOCAL_PREFETCH_WORKERS` overrides for ablation.

Remaining levers, in value order:
- **DMap decodes the stack twice** (argmax pass + render pass) — ~50 s
  of pure decode at 50 frames. Spilling warped fp16 frames to a temp
  file during pass 1 and streaming them back for the render pass
  (~360 MB/frame, sequential SSD I/O at multi-GB/s) could halve DMap
  decode cost. Worth prototyping with the phase instrumentation.
- **Upload/GPU overlap**: the per-frame memcpy + waitUntilCompleted
  serializes ~3 s of upload behind the GPU; double-buffering hides it.
  Small, do alongside other GPUPyramid work.
- Half-float pyramid buffers would halve GPU bandwidth, but the GPU is
  ~7 s of a ~35 s fuse — low value until decode is fixed.

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