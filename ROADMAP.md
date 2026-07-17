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

### Phase 0c: neutral image currency in the model

Replace `NSImage` in model-published state (`AppModel` previews,
`Stack.outputPreview`/`depthPreview`, `RetouchSession` source caches)
with the CGImage/ImageBuffer layer already beneath it; views wrap to
`NSImage` (or draw CGImage directly) at the edge. Done = AppCore free of
`NSImage`, retouch 45 MP paint still smooth (no per-frame conversions on
the paint path), UI tests pass.

### Phase 1: engine backend seams + Linux CI + portable CLI

Decode/encode, EXIF, simd-3×3, and spill backends behind build-time
selection (ImageIO/CIRAW on Mac; LibRaw + libjpeg-turbo/libtiff/libpng +
lcms2 + exiv2 elsewhere; DNG SDK flips `qMacOS` → `qLinux`/`qWinOS` —
the vendored SDK already supports both). Linux container CI running
synth → fuse → PSNR (synth fixtures are TIFF, so baselines port
unchanged). Done = `hyperfocal-cli fuse/batch/synth/compare` passes the
synth gates on Linux.

### Phase 1.5: OpenCV vs Vision registration gate

OpenCV `findHomography` behind `Aligner.register(moving:fixed:)`'s
existing `(gray CGImage, gray CGImage) → simd_float3x3` seam (mind the
bottom-left→top-left convention flip in `Aligner.convention`). A/B via
the residual scores `Aligner` already computes, synth PSNR, and the
fluorite mineral stack. Outcome recorded in the plan doc: adopt
everywhere, or keep Vision on Mac and document the divergence.

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
