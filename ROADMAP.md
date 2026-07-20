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
standard gate invocation (verify skill; default params, `--color-space p3`). The engine's Apple
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

Real-frame RAW decode, color, and the as-shot neutral are verified on
Linux (2026-07-19: real DNG stack; DNG round-trip 93 dB; exported
AsShotNeutral closed-loop). Verification used DNGs deliberately — lossy
(High Efficiency) NEFs can't be decoded by any open-source library and
the workaround is punted; see
`Docs/research/2026-07-19-lossy-nef-linux.md` before revisiting.

The Windows bring-up landed too (2026-07-19): `swift build` and
`Scripts/ci-gate.sh` are green on Windows 11 arm64 (Swift 6.3.3, VS 2022
Build Tools, vcpkg-supplied C stack — build recipe in README "Building
on Windows", environment loader `Scripts/windows-env.ps1`). Gate
numbers: dmap 39.11 / pmax 38.66 / DNG round-trip 93.17 dB — within
noise of the Linux aarch64 baselines (same OpenCV registration + LibRaw
decode). Package.swift resolves the imaging libraries from
`VCPKG_ROOT`/`VCPKG_TRIPLET` at manifest-eval time (the Windows
analogue of the Linux pkg-config path); `FrameSpill` has a Win32
positional-I/O backend (OVERLAPPED offsets, DELETE_ON_CLOSE).

The Qt shell also runs on Windows (2026-07-19): `QtShell/build.ps1`
builds it against an aqt-installed Qt 6.10.3 (msvc2022_arm64 cross kit —
bundles its own x64 host tools; qtshadertools added with `--noarchives
-m`), and the four-variant selftest matrix passes (base+EXPECT_DISPLAY
889x590, EXPECT_EXCLUDED misfire, plain, STACK2 batch). The shell builds
Release only: Qt's debug DLLs use the debug CRT, which the always
release-CRT Swift runtime can't join — the C bridge boundary makes a
debug bridge under the release shell the dev loop instead.

Windows residuals to close (each independently landable):

1. **Non-ASCII paths on Windows.** CImaging opens files with
   `fopen`/`TIFFOpen`/`LibRaw::open_file(char*)`, which Windows
   interprets in the ANSI codepage while Swift hands over UTF-8 —
   frames in folders with non-ASCII names will fail to open. Fix is
   either an app-manifest UTF-8 codepage opt-in or `_wfopen`-family
   conversions in the shim.
2. **Windows CI runner** (plan Phase 1 names Windows CI): ci-gate.sh
   already passes under Git Bash with the environment from
   `Scripts/windows-env.ps1`; needs a GitHub Actions windows job (or
   self-hosted arm64 runner) and possibly Windows-calibrated floors —
   measured margins above the shared floors (2026-07-20): dmap ≥ 0.4 dB,
   pmax 0.25 dB (38.55 vs floor 38.3; the registration gray-path fast
   path shifted the crop by a pixel, which moved pmax from 38.66).
3. **CLI DLL deployment.** The exe finds vcpkg's DLLs via PATH
   (windows-env.ps1 prepends `installed\<triplet>\bin`); distributing
   the CLI needs the DLL set copied beside the exe or a static-triplet
   build decision.
4. **Fusion throughput on modest hardware.** Reference point (82 × 11 MP
   JPEGs, 2-core Windows VM, 2026-07-20, debug build): ~7.8 min end to
   end — registration ~4.5 min, pmax fusion 198 s (2.4 s/frame CPU;
   phase buckets: warp 85 s, build 90 s, select 19 s, decode hidden by
   prefetch). ~1 s/frame fusion and < 2 min end-to-end are demonstrably
   achievable on the same 2 cores (measured against commercial stackers
   on this VM). Remaining levers, largest first: (a) `laplacianPyramid`
   allocates fresh buffers per level per frame and runs blur / decimate
   / upsample / subtract / energy as separate materialized passes —
   preallocate a workspace and fuse them (blur+decimate computes only
   even outputs; band+energy+select streams without materializing
   bands); (b) SIFT detect ~2.3 s/frame (OpenCV-bound) dominates
   registration. Measure with `-v` phase buckets +
   `HYPERFOCAL_REGISTER_DEBUG` / `HYPERFOCAL_DECODE_DEBUG`. Before
   touching any per-pixel loop, read PortableSIMD.swift's performance
   contract: cross-file generic calls don't specialize in per-file
   debug builds — that trap cost 55x in the warp until 2026-07-20.

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

Shell signal granularity is load-bearing for responsiveness: the
facade caches and diffs per bridge callback, emitting tick (panes,
which self-guard by pixel epoch), progressChanged, framesChanged /
stacksChanged (only when list content really moved), and changed()
only when the remaining-scalar fingerprint moved — a single coarse
signal made every fusion progress tick rebuild both sidebar ListViews
and froze the UI.

The shell keeps its own settings store (`HYPERFOCAL_SETTINGS_SUITE`,
set to `org.hyperfocal.qtshell-settings` in main.cpp before any hf_*
call) — nothing bleeds between the shells' persisted state.

The shell also runs on Linux (Ubuntu Qt 6.10 via `QtShell/build.sh`;
the four-variant selftest matrix passes on the Ubuntu box). Two
Linux-only load-bearing facts: `hf_pump_main()` (bridge) drains the
Swift main queue from a 5 ms QTimer in main.cpp — without it no
main-queue/MainActor work ever runs under Qt's loop off-Apple; and
Package.swift links only the OpenCV modules CImaging uses, because
Ubuntu's `opencv4.pc` otherwise links `highgui`, whose Qt 5 corrupts a
Qt 6 process during loader init. Selftest journeys that compare input
pixels must gate on `hf_input_loading` (the title names the new frame
before the decode lands — the stale-pixel race only shows on slow
machines).

**Feature parity with the native app was reached 2026-07-19** —
retouch landed last: the session stays in AppCore behind hf_retouch_*
(strokes/hover in full-image px, brush via the slider id namespace,
source kinds/cycling/auto-pick, PMax build+cancel, revert; hf_undo
mode-scopes to "Undo Stroke"); while active, hf_display_* serves the
session's zero-copy working/depth image, and strokes bump the epoch
with a union dirty rect (hf_display_dirty) the pane uses to evict only
touched tiles (coarse base refetches debounced). The left pane
reroutes to hf_retouch_source_*; RetouchOverlay.qml draws the brush
circle under the canPaint rule; the selftest paints a stroke and
proves edits→dirty-epoch→"Undo Stroke"→revert→exit. Remaining polish,
in priority order:

1. **Crop-overlay polish** (from Ethan's 2026-07-19 review; not
   urgent): proper rotation cursors matching the native macOS
   sector-oriented rotate cursors (Qt has no built-in rotate cursor —
   needs custom cursor images quantized to the 8 sectors like
   ContentView.swift:2093-2103); (Hotkey menu items landed
   2026-07-19: Edit carries Crop/Swap Orientation/Accept/Cancel.)

**Known deviations & placeholders** in already-built Qt features —
the running list of "works, but not the native way" (new
simplifications must be added here the moment they're made, so
reviewers stop discovering them by surprise):

- Confirms/notices are Qt message boxes (idiomatic on Linux; visibly
  non-native chrome on macOS).
- Batch-fuse and bulk-export summaries arrive as notice dialogs — the
  native queueSummaryPresenter styling differs.

## Engine performance

### wgpu compute backend (plan Phase 4, in progress)

Windows/Linux GPU fusion via one wgpu/WGSL backend translated from the
Metal kernels (plan decision 3). The scaffold is landed opt-in
(2026-07-19): build with `HYPERFOCAL_WGPU=1` + `WGPU_ROOT` pointing at a
wgpu-native prebuilt (v29.0.1.1; default `../wgpu-native`), giving
`Sources/CWgpu` + `WgpuEngine` (WGSL library, pipeline cache,
upload/download, per-dispatch bind groups) and the
`hyperfocal-cli debug-wgpu` kernel-parity harness (`WgpuParity`, floor
90 dB). All 27 kernels are translated and passing — 16 bit-identical,
the rest 129–164 dB (transcendental precision), minimum 129.6 dB
(warp_lanczos3; both warps check against the production `Warp.apply`,
the rest against inline references mirroring the MSL) — measured on
D3D12 WARP (the Windows-on-ARM VM has no hardware DX12; WARP validates
correctness, real speedups need hardware). Kernel conventions: bindings
in `run`'s order (storage 0..n-1, uniforms last, padded to 16-byte
multiples); guided_apply_blend needs 9 storage buffers, which is why
the engine requires the adapter's real limits at device creation (the
spec default is 8) and callers without spill data bind 1-float
dummies.

Both fusion paths run on it (2026-07-19). `WgpuPyramid` and `WgpuDMap`
mirror the Metal orchestrations through `WgpuEngine.Batch` (one
command-buffer submit per frame; per-dispatch bind groups; uniforms via
queue-ordered `wgpuQueueWriteBuffer`, which also makes Metal's
ping-pong upload buffers unnecessary — writes staged during the
previous frame's GPU work apply in queue order). GPUDMap's mid-frame
CPU dependency (exposure gain measured on the *warped* frame between
the warp and argmax dispatches) costs a readback here — it shares the
download with the frame spill, and unwarped frames skip it entirely.
Wired into `PyramidFusion`'s preferGPU seam, `StackPipeline`'s dmap
seam, and the CLI's `--engine` resolution — preferGPU is effectively ON
for Windows/Linux wgpu builds (auto → wgpu when an adapter exists).
Gates, all green on WARP: `debug-wgpu` runs kernels (floor 90, min
129.6 dB), `runFusion` (pyramid, floor 60: 139–145 dB, preview collapse
bit-identical), and `runDMap` (SynthStack plane scene in a temp dir,
spill + prefetch + flickered exposure gains live, floor 90: 116–132 dB;
the check needs a realistic stack — strip-scene frames give dmap's
argmax dense near-ties that flip whole frame indices on fp noise).
File-level: pmax 97.6/102.4 dB CPU↔GPU, dmap 121.4 dB (depth 105.7);
ci-gate needed no recalibration — GPU-path ground-truth PSNR matches
the CPU baselines to two decimals (39.11 dmap / 38.66 pmax). Remaining:

1. Decide packaging: wgpu-native ships as a prebuilt DLL/so — vendor per
   platform, or fetch in CI like Qt/vcpkg (deployment story joins the
   CLI-DLL residual above).

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

### Retouch stamp cost at large brush radii — verify feel, then close

The engine-side fixes landed 2026-07-19 (all in `RetouchSession`, so
both shells inherit them): stroke arc-length carry so stamps land
every `spacing` along the path instead of ≥ once per mouse event (the
dominant cost — per-event stamping did ~65× the intended work at max
radius), per-row chord bounds + core sqrt skip, SIMD4 blend with
parallel rows (serial under 128 rows), and memcpy undo-tile capture.
Measured on a 45 MP synth stack via the probe's bench harness
(`HYPERFOCAL_BENCH_STROKE=1 retouch-probe <frames…>`, VM-loaded
machine): max-radius 4954 px drag 36.3 s → 0.56 s; warm click 54 →
45 ms; steady-state stamp ≈ 5 ms snapshot + 20 ms paint (paint is
memory-bound, not compute-bound — SIMD alone moved nothing until rows
were parallelized). Remaining:

- **Feel-check in the native app** (the item's done criterion): a
  max-radius drag on a 45 MP stack should feel continuous. Note the
  first stamp after a source-frame load pays a one-time cold-page
  cost (~0.4 s at 45 MP in the bench); if that reads as a real-world
  stutter, pre-warm the working/display buffers on session start.
- If more is ever needed: parallelize `snapshotTiles`' 49-tile copy,
  or accumulate a per-segment coverage mask and composite once.

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

