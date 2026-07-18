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

## Cross-platform port (Windows/Linux)

Strategy and phases: `Docs/cross-platform-plan.md` (decided 2026-07-17;
evidence in `Docs/research/2026-07-17-windows-linux-port-evaluation.md`).
Summary: Mac keeps the native app untouched; Windows/Linux share one Qt
shell that also builds on macOS as a dev/validation target; shared Swift
core (`HyperfocalKit` + extracted `AppCore`) everywhere; CIRAW stays on
Mac with LibRaw elsewhere; OpenCV replaces Vision registration on all
platforms if it validates. Work the phases in order; each item below is
independently landable and keeps all existing gates green.

### Phase 1: portable engine + CLI on Linux

The Linux bring-up landed (see git history + `Docs/cross-platform-plan.md`):
`swift build` is green on Ubuntu 26.04 / aarch64 with the distro swift.org 6.1
toolchain, and `hyperfocal-cli synth→fuse→compare` passes the **plane** synth
gate — dmap **39.1 dB** (≥ 38.7), pmax **38.6 dB** (≥ 38.3), measured with the
README invocation (default params, `--color-space p3`). The engine's Apple
paths stay behind `#if canImport(<Framework>)`; Linux decode/encode/EXIF/
registration go through a C-ABI shim (`Sources/CImaging` over libtiff /
libpng / libjpeg-turbo / LibRaw / lcms2 / exiv2 / OpenCV) wired into
`Package.swift` via pkg-config. TIFF/PNG/JPEG round-trips verified; the
registration seam moved off `CGImage` to a portable `GrayImage`.

System deps (Ubuntu): `swiftlang build-essential pkg-config libraw-dev
liblcms2-dev libexiv2-dev libjpeg-turbo8-dev libtiff-dev libpng-dev
zlib1g-dev libopencv-dev` (+ `libavformat/avcodec/avutil/swscale-dev
libgif-dev` for the later rocking backend).

Residuals to close (each independently landable; keep macOS green):

1. **macOS verification — blocks a merge.** The shared-code changes were
   written and only built on Linux. On a Mac, confirm `swift build &&
   retouch-probe … ALL PASS` and the synth PSNR baselines are unchanged —
   especially the registration seam refactor (`Aligner`/`ImageFile` moved off
   `CGImage` to `GrayImage`; the macOS gray bytes + Vision call are meant to be
   byte-identical, but that was not verifiable on Linux).

2. **Object-scene registration gap → the Phase 1.5 A/B.** Linux registration is
   OpenCV SIFT + RANSAC. The plane scene matches/exceeds Vision, but the object
   scene lags ~5 dB (35.9 vs 41.3): high-contrast subject edges punish
   sub-pixel residuals and SIFT features cluster on the lit subject. ECC
   refinement was tried and **reverted** — dense intensity alignment drifts
   across the defocus change between focus levels. Resolve as the A/B below.

3. **RAW + EXIF on real frames.** `hf_decode_raw` (LibRaw, output ProPhoto→P3
   via lcms2) and the exiv2 EXIF reads compile but are unexercised by the synth
   gate (TIFF, no EXIF). Verify against a real NEF stack; refine the RAW color
   mapping (the ProPhoto-output first cut) and surface the as-shot neutral
   (LibRaw `cam_mul`/`pre_mul`) that DNG export's WB un-bake reads — currently
   Apple-only, so Linux DNG declares a generic neutral.

4. **SIFT performance on big images.** Registration runs SIFT on full-res
   gradient images; on 45 MP stacks that is slow (unbounded features + O(n²)
   match). Bound it (downscale-for-registration or a feature cap) without
   losing the plane-gate precision.

5. **CI.** GitHub Actions Linux job: a container with the toolchain + the `-dev`
   packages above, `swift build -c release`, then synth→fuse→compare asserting
   PSNR ≈ the plane baseline.

Deferred within Phase 1 (stubs in place, not on the gate path): rocking export
(`RockingAnimation.write` throws on Linux — FFmpeg/giflib backend pending) and
capture-time EXIF *stamping* in `SynthStack` (ImageIO-only, for session-split
tests).

### Phase 1.5: OpenCV vs Vision registration gate

The seam is off `CGImage` (a portable `GrayImage` now), and OpenCV
`SIFT + findHomography(RANSAC)` is the Linux backend — mandatory there (no
Vision). Interim Linux finding: SIFT matches/exceeds Vision on the synth
**plane** (39.1 vs 38.7) but lags on the **object** scene (~5 dB); ECC dense
refinement hurt and was dropped. The A/B is not settled — it still needs a Mac
run (residual-score harness + synth PSNR + the fluorite mineral stack) to
decide whether *macOS* also drops Vision, or keeps it while Linux uses OpenCV.
Mind the convention: Vision reports bottom-left-origin warps (flip in
`Aligner.convention`); OpenCV is already top-left, so the Linux path takes no
flip. Record the outcome in `Docs/cross-platform-plan.md`.

## Engine performance

### GPUDMap pass 1: overlap upload with GPU work — measure first

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

### Research-informed fusion follow-ons

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

## UI fixes

### Retouch canvas ignores the crop

Entering retouch on a cropped stack shows the entire uncropped image
(reported by Ethan 2026-07-17; pre-existing, not a regression). The
preview panes clip to the crop at draw time — inner container = the
crop region's view rect (`ContentView.swift` `PreviewPane`, "nothing
outside the crop ever renders") plus the rotated-crop clip path in
`TonedImagePaneNSView.draw` — but `RetouchCanvasNSView.draw` has no
crop handling at all and draws the full working buffer. Fix: give the
retouch canvas the same cropped-canvas presentation the panes use
(the shared pan/zoom coordinate space is the *cropped* canvas — see
the nominalSize comments in ContentView). Mind that strokes and the
session's tile invalidation work in full-image coordinates, so the
display clip/offset must not shift where paint lands; rotated crops
need the same clip-path treatment as the toned pane. Done = entering
retouch with a crop (including a rotated one) shows only the cropped
region, aligned with the panes at every zoom, strokes land exactly
under the brush, and RetouchJourney gains a crop-then-retouch step
verifying pixels via the export command channel.

### Zoom values are broken

Something has caused a regression, where 100% zoom is apparently no
longer taking the image display scale into account - 50% zoom is
actually the correct 1:1 zoom on my 2x retina screen.
