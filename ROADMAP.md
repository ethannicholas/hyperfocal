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

### Phase 1: portable engine + CLI on Linux — bring-up guide

**Do this in a Linux session** (swift.org toolchain); this macOS machine
can't compile the non-Apple paths, so the work below was written but not
built here. Scope is `HyperfocalKit` + `hyperfocal-cli` only — the app,
`AppCore/`, and `retouch-probe` are macOS/Qt-shell targets (later
phases). Strategy and decisions of record: `Docs/cross-platform-plan.md`
(CIRAW stays on Mac, LibRaw elsewhere; CPU-only first, Metal dropped).
Done = `hyperfocal-cli fuse/batch/synth/compare` passes the synth gates
(header baselines, esp. plane ≈ 38.7 dB) on Linux, in CI.

Follow the pattern the simd shim already set: gate the Apple `import`
with `#if canImport(<Framework>)`, and put the portable implementation
under `#else`. `retouch-probe` is AppKit-only and stays the *macOS*
gate; the *Linux* gate is the CLI synth→fuse→compare path (synth
fixtures are TIFF, so the PSNR baselines port unchanged).

**Already landed / already portable:** the simd 3×3 shim
(`Sources/HyperfocalKit/PortableSIMD.swift` — pure-Swift `Float3x3` +
`simd_*` aliases active only under `#if !canImport(simd)`; `import simd`
is conditional in the non-Metal engine files + CLI; probe cross-checks
it against Apple's simd on macOS). The ~3,100-LOC fusion core
(`DMapFusion`, `DepthRegularize`, `PyramidFusion`, `Filters`, `Warp`,
`ToneCurve`, `ImageBuffer`, `StackPipeline`) needs only Foundation /
Dispatch / stdlib-SIMD. The vendored DNG SDK and `XMPSidecar` are
portable (see item 4).

Work items (roughly in order; each keeps macOS green — verify with the
probe + synth PSNR after touching shared code):

1. **Exclude the Metal path.** `GPUDMap.swift`, `GPUPyramid.swift`,
   `MetalEngine.swift` `import Metal` (and still `import simd`
   unconditionally). Wrap each whole file in `#if canImport(Metal)` (or
   exclude via `Package.swift` on non-Apple) and confirm nothing outside
   them names an `MTL*`/`MetalEngine` type unguarded — callers gate on
   `MetalEngine.shared != nil`, so `MetalEngine.shared` needs a
   non-Metal stub returning nil (CPU path is the reference; `preferGPU`
   then always falls through to CPU). This unblocks the whole Linux
   compile.

2. **Decode/encode — the big one (`ImageFile.swift`,
   `import CoreImage/ImageIO/CoreGraphics/UniformTypeIdentifiers`).** The
   single decode/encode hub; everything downstream consumes `ImageBuffer`
   (Float32 RGBA, Display P3), so the seam is contained here. Replace:
   RAW via **LibRaw** (full-quality demosaic, `use_camera_wb`, `flip`
   orientation, `cam_mul`/`pre_mul` for the as-shot neutral that
   `DNGWriter` reads as `neutralChromaticity`); JPEG/TIFF/PNG (8- and
   16-bit) via libjpeg-turbo / libtiff / libpng; P3 tagging + conversion
   via **lcms2** (replaces the CoreGraphics tagged-colorspace draws).
   `CGImage` is CoreGraphics — see the caveat below; `cgImage8/16` and
   `loadGray8CGImage` need a portable image handoff on Linux.

3. **EXIF (`StackSplitter.swift`, `DNGWriter.sourceMetadata`,
   `import ImageIO`).** Property-dict reads → **exiv2** (or libexif):
   `DateTimeOriginal` + `SubSecTimeOriginal` for capture-time stack
   splitting, and Make/Model/lens/exposure/ISO/GPS for DNG carry-over.

4. **DNG output (`Package.swift` `CDNGSDK` target).** Flip
   `.define("qMacOS", to: "1")` → `qLinux`/`qWinOS` (the vendored SDK
   has first-class support in `dng_flags.h`; only `zlib` is linked, XMP
   /libjpeg/JXL already compiled out). The C shim and `import CDNGSDK`
   are unchanged. `DNGWriter.writeUncompressed` (pure-`Data` fallback)
   and `XMPSidecar` (hand-rolled bytes) are already portable.

5. **Spill (`FrameSpill.swift`).** Already POSIX. Darwin-only bits:
   `fcntl(fd, F_NOCACHE, 1)` (line 75) → `posix_fadvise(..., DONTNEED)`;
   `volumeAvailableCapacityForImportantUsage` (lines 47-48) → `statvfs`.
   Unlink-after-open works on Linux as-is.

6. **Rocking export (`RockingAnimation.swift`,
   `import AVFoundation/ImageIO`).** MP4 → FFmpeg, GIF → giflib; the
   warp/disparity math (~180 LOC) is already portable. **Deferrable** —
   stub `RockingAnimation.write` to throw "unsupported" on Linux so the
   core `fuse`/`batch` CLI ships first; it's not on the synth-gate path.

7. **`Package.swift` + CI.** Add `systemLibrary` targets (pkg-config)
   for libraw/lcms2/exiv2/libjpeg-turbo/libtiff/libpng; make target
   sources / dependencies platform-conditional. GitHub Actions Linux
   job: container with the swift toolchain + those `-dev` packages,
   `swift build -c release`, then `synth → fuse → compare` asserting
   PSNR ≈ header baselines.

**Caveat — CGImage/Vision coupling forces registration on Linux.**
`Aligner.register(moving: CGImage, fixed: CGImage) -> simd_float3x3`
(line 67) uses Vision, and the whole registration path is `CGImage`-typed
(`loadGray8CGImage`, `gradientImage`). CoreGraphics *and* Vision are
Apple-only, so **Linux cannot defer the registration swap** the way
macOS can — the Linux build has no Vision at all. Do Phase 1.5 (below)
as part of this bring-up: introduce a portable gray-image handoff
(raw bytes or `ImageBuffer`, not `CGImage`) through `register` and back
it with OpenCV on Linux. Whether *macOS* also switches off Vision stays
the A/B decision in 1.5.

### Phase 1.5: OpenCV vs Vision registration gate

Put OpenCV `findHomography` behind `Aligner.register`'s seam — but first
change that seam off `CGImage` to a portable gray representation (see the
Phase 1 caveat; Linux has no `CGImage`). Mind the bottom-left→top-left
convention flip in `Aligner.convention`. On Linux OpenCV is mandatory
(no Vision); on macOS, A/B OpenCV vs Vision via the residual scores
`Aligner` already computes, synth PSNR, and the fluorite mineral stack —
if OpenCV matches, adopt it on macOS too (one engine everywhere), else
keep Vision on Mac. Record the outcome in `Docs/cross-platform-plan.md`.

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
