# Hyperfocal Roadmap

Working list toward public release, in priority order. Written to be
self-contained: each item says what, why, where in the code, and what "done"
looks like, so any future session (or contributor) can pick one up cold.
Shipped work and rejected approaches are stripped entirely — no "this
shipped" narratives, no why-we-didn't explanations; git history, the
README, and `Docs/research/` are the record.

Regression gates: `swift build && .build/debug/retouch-probe <synth
frames…>` must print `probe: ALL PASS`, and `hyperfocal-cli synth`
baselines (default params) are **plane ≈ 38.7 dB dmap / 38.3 pmax** vs
truth, **object ≈ 41.3** (defaults sharpness σ = 10 / guided radius 128 /
median radius 20, 2026-07-13). CPU↔GPU parity: ≥ 90 dB both methods
(measured ~114 dmap / 106 pmax on the synth plane) — re-check before
trusting any algorithm change.

---

## Release blockers

None outstanding (as of 2026-07-17).

---

## Engine performance

### 3. GPUDMap pass 1: overlap upload with GPU work — measure first

GPUPyramid overlaps frame N+1's decode wait and upload memcpy with frame
N's GPU work (ping-pong upload buffers, deferred wait — and note its
`gpu` bucket in the `pyramid phases:` -v line therefore reads
*blocked-on-GPU*, not GPU execution). GPUDMap pass 1 still serializes
upload → warp → wait per frame, and it's a harder port: the exposure
gain is measured from the *warped* frame mid-frame (`meanLuminance`
between the warp and argmax command buffers), a genuine CPU dependency
the pyramid path doesn't have. GPUDMap has no phase-bucket logging at
all yet — add GPUPyramid-style buckets and measure the blocked-on-GPU
share on a 45 MP NEF stack first; fusion at 45 MP is RAW-decode-bound,
so build nothing until the measurement says there's something to hide.
Done = buckets in -v output, and either the overlap ported (output
byte-identical, blocked-on-GPU ≈ 0) or this item deleted because the
measurement showed nothing worth hiding.

### 3a. Research-informed fusion follow-ons

From the 2026-07-12 deep-research pass — **full findings, evidence
quotes, source list, refuted claims, and open questions are in
`Docs/research/2026-07-12-focus-stacking-research.md`** (with raw
workflow outputs alongside); consult it before revisiting any of this.
Key sources: Pertuz et al. Pattern Recognition 2013 [the 36-operator SFF
benchmark]; Jeon et al. IEEE TIP 2019 [Ring Difference Filter]; Ali et al.
Pattern Recognition 2021 + CVIU 2022 [guided-filter depth refinement];
Moeller et al. IEEE TIP 2015 [variational DfF]; zerenesystems.com and
heliconsoft.com primary docs.

The depth regularizer under discussion is `DepthRegularize.swift`
(ablation env switches `HYPERFOCAL_GUIDED_NO_TIER2` / `_NO_TIER2_MASK` /
`_FIXED_EPS`). Judge each follow-on against the specular-bokeh mineral
stack — fluorite specimen on marble, subject sharp mid-stack, tail
focused past it (full-res NEFs in `~/Desktop/Fluorite`; reshoot to that
recipe if it's gone):

- **Focus-measure upgrades to evaluate**: Ring Difference Filter kernel
  (local accuracy + non-local noise robustness, public code), multi-scale
  dilated Laplacian; variance or Tenengrad as a noise-robust
  *complementary gate* (statistics-based measures are the most
  noise-robust family; Laplacian is the least, and degrades above ~30%
  saturation — i.e. on speculars).
- **Render**: energy-weighted averaging *only inside low-confidence
  regions* (must stay regional — global energy-weighting sacrifices
  sharpness, Helicon Method A); reserve pyramid fusion for flagged
  overlap/discontinuity regions (the automated version of the
  vendor-documented "DMap base retouched from PMax" hybrid).
- **Stronger regularization, only if artifacts demand it**: aggregate the
  focus *cost volume* before argmax (RDF-style, or separable 3D-WLS per
  Ali/Pruks/Mahmood 2019 — tridiagonal 1-D solves, plausibly GPU-feasible
  at grid resolution) — upgrade stages within the current structure; the
  research doc's refuted-claims section covers the restructuring
  question. One known bounded behavior to watch for: where the guide is
  flat across a confidence rim, ramps meet plateaus with a seed-side
  bias (probe bounds it < 4 frames on the synthetic ramp); a 2-pass
  iteration is the flagged remedy if a real stack ever shows it.

Open (unresearched despite two passes): fusion-quality metrics
(Q_AB/F, MI, SSIM-variants) for the regression suite, and Core
ML-portable 2020+ fusion/DfF networks — needs a dedicated metrics pass
if wanted; PSNR-vs-synthetic-truth remains our gate meanwhile.

Gates: synth baselines in the header, probe ALL PASS, CPU/GPU parity,
and the mineral stack's three regions (shadow under the rim, substrate
above the specimen, silhouette band) eyeballed against Helicon's result.


---

## Community candy (post-1.0 or launch-adjacent)

### 5. Synthetic stereo pairs

The rocking-animation reprojection (`RockingAnimation`, gather-warp with
destination-depth disparity) at a fixed ± disparity gives left/right
eyes — export side-by-side and crossed-eye PNG pairs. At stereo-scale
disparities the gather approximation may need revisiting (the old
`nearestSeedFill` jump-flood, removed 2026-07-12, is in git history if
splat + inpaint wins).

Depth *direction* matters here, unlike the rocking loops (negated
disparity there is just a half-cycle phase shift of the symmetric
cycle): a fixed per-eye offset with inverted depth swaps the eyes and
reads inside-out. Stereo needs a direction control or auto-detection —
and note the app re-sorts frames by capture time at load
(`StackSplitter.ordered`), so a "backwards" stack can only arise from
shooting far-to-near, not from shuffled files.

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
