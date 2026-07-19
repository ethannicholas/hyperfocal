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
Mac with LibRaw elsewhere; registration is Vision on macOS and OpenCV on
Linux (decided 2026-07-18 — see plan decision 2). Work the phases in
order; each item below is independently landable and keeps all existing
gates green.

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
registration seam moved off `CGImage` to a portable `GrayImage`. macOS
re-verified after the bring-up: `retouch-probe` ALL PASS, synth baselines
unchanged (plane 38.71/38.26, object 41.29), UI suite green — the
`GrayImage` seam is byte-identical on the Apple/Vision path.

System deps (Ubuntu): `swiftlang build-essential pkg-config libraw-dev
liblcms2-dev libexiv2-dev libjpeg-turbo8-dev libtiff-dev libpng-dev
zlib1g-dev libopencv-dev` (+ `libavformat/avcodec/avutil/swscale-dev
libgif-dev` for the later rocking backend).

Residuals to close (each independently landable; keep macOS green):

1. **RAW + EXIF on real frames.** `hf_decode_raw` (LibRaw, output ProPhoto→P3
   via lcms2) and the exiv2 EXIF reads compile but are unexercised by the synth
   gate (TIFF, no EXIF). Verify against a real NEF stack; refine the RAW color
   mapping (the ProPhoto-output first cut) and surface the as-shot neutral
   (LibRaw `cam_mul`/`pre_mul`) that DNG export's WB un-bake reads — currently
   Apple-only, so Linux DNG declares a generic neutral.

2. **SIFT performance on big images (bound proven on macOS — port to Linux).**
   Full-res SIFT on 45 MP frames needs ~7.5 GB and often finds no model. The
   fix — register on a downscaled copy (longest side 2500 px) and map the
   homography back via `S⁻¹·H·S` — is implemented and validated in the macOS
   A/B path (`Aligner.registerOpenCV`/`boxDownscale`; it made the 60×43 MP
   fluorite stack register cleanly, residuals matching Vision). Port the same
   downscale wrapper to the Linux `register(GrayImage,GrayImage)` call site
   (its `hf_register` call is currently unbounded); synth frames sit below the
   bound so the plane gate is unaffected.

3. **CI.** GitHub Actions Linux job: a container with the toolchain + the `-dev`
   packages above, `swift build -c release`, then synth→fuse→compare asserting
   PSNR ≈ the plane baseline.

Deferred within Phase 1 (stubs in place, not on the gate path): rocking export
(`RockingAnimation.write` throws on Linux — FFmpeg/giflib backend pending) and
capture-time EXIF *stamping* in `SynthStack` (ImageIO-only, for session-split
tests).

### Phase 2: C-ABI bridge + Qt shell

The shell is landed on macOS: AppCore is a real SwiftPM module (plan
0d structure; the Mac app still compiles the same sources directly —
no module boundary there), the probe consumes it via `@testable
import` (white-box harness; its reach never forces internals public),
and `Bridge/HyperfocalBridge.swift` is a SwiftPM dynamic-library
product over it whose public-API needs define AppCore's public
surface. The bridge exports the `hf_*` surface in
`QtShell/hyperfocal_bridge.h`; `QtShell/` is the Qt 6 shell (build:
`QtShell/build.sh`, needs Homebrew qtbase/qtdeclarative/
qtshadertools + cmake ≥ 3.22). `hyperfocal-qt --selftest <stack> <out.tif> [shot.png]` self-drives
open → fuse → tone → export (result + depth) → window grab and exits
nonzero on failure — the seed of the Qt journey harness. Env hooks:
`HFQT_AUTOCONFIRM=1` answers modals with their default (the native
suite's HYPERFOCAL_AUTOCONFIRM, mirrored); `HFQT_EXPECT_EXCLUDED=<i>`
asserts frame i lost its checkbox during the fuse (run against a
`--misfire-frame` synth stack, this exercises the bad-frame confirm
through the bridge dialog seam end-to-end); `HFQT_EXPECT_DISPLAY=WxH`
asserts the display serves the full result resolution (the runner knows
the fused size); `HFQT_STACK2=<dir>` runs the batch journey (a second
stack is added after the first load settles, "Fuse N Stacks" walks
both, and both must end fused with nothing pending). The sidebar
mirrors the native app: stack tree (flat) with enable checkbox, status
glyph, frame count, row-click select (stash/install); frame rows select
into the input pane (aligned once transforms exist, shared viewport
with the output pane, toned like the native app); hf_load_stack has
drop semantics (folders ADD stacks; a .hyperfocal project
opens/replacing). Display currency is production-shaped: tone is a LUT
shader on the pane layer (hf_tone_lut; parity with the CPU-toned render
0.03/255), and the pane is a tiled textured QQuickItem over
hf_display_tile/hf_display_epoch — level-of-detail matched to on-screen
scale up to full-res at 1:1 zoom, matrix-only pan/zoom, tone edits never
invalidate tiles (the selftest asserts the epoch holds). Crop presents
natively (hf_display_crop/hf_input_crop viewport + rotation about the
rect center, clip between the pan/zoom and rotation transforms;
hf_set_crop is the UITest set-crop seam; the selftest proves epoch
stability and the 400×300 export through the 5° sampler).

The shell keeps its own settings store (`HYPERFOCAL_SETTINGS_SUITE`,
set to `org.hyperfocal.qtshell-settings` in main.cpp before any hf_*
call) — nothing bleeds between the shells' persisted state.

Next, in rough order (each independently landable):

1. **Qt shell on Linux — bring-up.** The shell + selftest matrix runs
   only on macOS today; the blockers, in dependency order:
   - *AppCore portability (the load-bearing chunk).* `AppModel.swift`
     imports SwiftUI, Combine, CoreGraphics, and
     UniformTypeIdentifiers with **no** `canImport` guards; the
     published image currency (`outputPreview`, `progressive`,
     `depthPreview`, `inputPreview`, `processingSource`) is `CGImage`;
     the bridge subscribes `objectWillChange` (Combine) and serves
     tiles via `CGImage.cropping` + `CGContext` draws. Needed: the
     plan's 0d observation seam (or OpenCombine), a portable image
     handle for published previews (ImageBuffer-backed, with the
     CGImage path kept behind `canImport(CoreGraphics)` — the engine
     below is already portable, Phase 1 proved it), and
     `#if canImport` partitioning of the SwiftUI/UTType touches. Most
     of this is macOS-verifiable against the existing gates (probe,
     UI suite, Qt selftest matrix) before Linux ever runs it. The
     build topology is already in place: AppCore is a SwiftPM module
     and the bridge a SwiftPM dynamic-library product (CMake finds
     libHyperfocalBridge per-platform); what remains is moving the
     AppCore/bridge targets out of the `#if os(macOS)` block in
     Package.swift once they compile portably.
   - *Main-queue pumping.* DispatchQueue.main drains under Qt's loop
     on macOS via CFRunLoop; Linux needs an explicit pump (Qt timer
     or glib hook) — the prototype's known deferred question.
   - *Deps.* Phase 1's package list plus Qt 6: Ubuntu
     `qt6-base-dev qt6-declarative-dev qt6-shadertools-dev` and the
     QtQuick Controls/Dialogs/Layouts QML modules
     (`qml6-module-qtquick-*`).
   - *Done =* the four-variant selftest matrix exits 0 on Linux:
     plain, `HFQT_EXPECT_DISPLAY=WxH` on a >1600px stack,
     `HFQT_EXPECT_EXCLUDED` on a `--misfire-frame` stack, and
     `HFQT_STACK2` batch. Runner notes: derive the expected display
     WxH from a first run's export (the fuse insets ~1px/side even
     with `--jitter 0 --breathing 0`); `--misfire-frame` refuses the
     middle (reference) frame — sabotage a different one.
2. **Crop editing in the Qt shell** (the drag-handle overlay is
   native-only; the bridge already speaks hf_set_crop, so this is a QML
   overlay over the output pane feeding the same call — the sidebar's
   numeric fields are the stand-in).
3. **Dirty-rect tile invalidation** once a partial-update producer exists
   (retouch strokes in the Qt shell): today any epoch bump drops every
   tile, which is right for wholesale changes (progressive updates, new
   fuse) and wasteful only for localized ones — build it with the
   feature that needs it.

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

