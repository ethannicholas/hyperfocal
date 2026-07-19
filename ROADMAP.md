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

**UI parity with the native app** is the phase's current goal (Qt is
functional but rough; inventory taken 2026-07-19 against
ContentView/HyperfocalAppMain/SettingsView). In rough priority order,
each independently landable:

1. **Noise-floor live depth preview** on slider drag (begin/end bridge
   calls mirroring beginNoiseFloorPreview/end).
2. **Retouch in the Qt shell** — the largest piece: full session
   surface over the bridge (enter/exit, brush size/softness, source
   kind picker + frame cycling + auto-pick, strokes with the
   image-space dirty rects, PMax build/cancel/progress, revert,
   stroke undo), a paint-canvas item, and dirty-rect tile invalidation
   in the pane (deferred item below). Sidebar completeness (tone/
   fusion resets, cancel, badges, include-all/none, counts) and
   undo/redo (hf_undo/redo/titles + the hf_tone_editing drag bracket —
   tone sets outside a bracket are silent to undo; Qt sliders bracket
   via pressed state; StandardKey shortcuts) landed 2026-07-19, as did
   project lifecycle: hf_save_project (NULL path = Save to the existing
   file, the Save/Save-As split) / hf_project_path / hf_has_unsaved_work
   / hf_close_stack / hf_close_project; menu bar (File/Edit, native
   system bar on macOS per Qt 6.8+ Menu adoption), dirty-marked window
   title, unsaved-work quit gate, folder drag-drop, pane empty-state
   hints, and a selftest save→reload round-trip (exit 16). Export flows
   followed the same day: persisted format/color-space/strength options
   (hf_*_format/color_space/animation_strength by native UI names), the
   export save dialog with the format choice unified into the filter
   combo and a labeled Color Space accessory row (Qt's widget
   QFileDialog in non-native mode — the only Qt dialog that hosts
   accessory rows; standard on Linux/Windows, trades the Finder
   sidebar on macOS; DNG switches the popup to read "Linear Display
   P3" and disables it, the native accessory's rule), the full
   extension→format map in Shell::exportTo (the selftest exports TIFF
   + DNG through it), the
   Depth label swap, and async export-all / export-aligned / rocking
   animation (started by hf_export_all/aligned/animation, summaries
   through the notice seam; Linux animation still needs the
   FFmpeg/giflib backend from the Phase 1 deferred list). The crop
   overlay landed 2026-07-19: a transactional crop-mode session over
   the bridge (hf_begin/accept/cancel_crop, hf_edit_crop for the live
   un-gated rect, aspect/orientation by native label — geometry
   authority stays in the model), with the QML overlay
   (QtShell/CropOverlay.qml) porting the native drag math verbatim:
   move with interior-rounded bbox clamping, anchored resize with
   aspect lock and 32px min, unwrapped rotation with 20-step bisection
   to the containment stop, corner-containment as the universal gate;
   C/X/Return/Esc keys and the aspect/orientation controls bar mirror
   the native CropControls. The selftest walks the session
   (begin→full-canvas init→accept folds to no-crop). The zoom bar
   landed 2026-07-19: −/%/+ cluster with a Fit + fixed-levels menu by
   the mode picker, ⌘+/⌘−/⌘0 shortcuts, PaneItem
   zoomBy/setAbsoluteScale/fit + displayScale on a viewportChanged
   signal, acting on the shared two-pane viewport. The settings window landed
   the same day: Edit > Settings… (⌘,) with the five pipeline toggles
   by native label over hf_bool_setting/hf_set_bool_setting (native
   settings.* id leaves) and hf_gpu_available gating Use GPU.
3. **Crop-overlay polish** (from Ethan's 2026-07-19 review; not
   urgent): proper rotation cursors matching the native macOS
   sector-oriented rotate cursors (Qt has no built-in rotate cursor —
   needs custom cursor images quantized to the 8 sectors like
   ContentView.swift:2093-2103); and hotkey discoverability — every
   shortcut (C for crop, X for orientation, …) should also exist as a
   menu item so the keys are learnable from the menus, not just
   documentation.
4. **Chrome**: About panel (+ DNG SDK credits), Help link, stack
   section collapse, disabled-stack dimming, per-stack inline frame
   disclosure in the multi-stack tree.

**Known deviations & placeholders** in already-built Qt features —
the running list of "works, but not the native way" (new
simplifications must be added here the moment they're made, so
reviewers stop discovering them by surprise):

- Animation export: the save dialog's mp4/gif filter choice does NOT
  drive the written format — the persisted animationFormat setting
  does, so a mismatched extension writes the other container. Native
  keeps them in sync via its accessory (which also offers
  format/duration/fps/path pickers the Qt dialog lacks).
- Input pane title reads a static "Input" mid-fuse instead of the
  native cycling processing-source label (hf_input_title's running
  branch is a stub).
- Progress lives in the sidebar, not overlaid on the output pane, and
  the ETA rides inside the stage text rather than its own label.
- The multi-stack tree is flat: frames listed for the selected stack
  only — no per-stack disclosure rows, no persisted stack-section
  collapse, no dimming of disabled stacks' rows.
- Confirms/notices are Qt message boxes (idiomatic on Linux; visibly
  non-native chrome on macOS).
- Save As suggests no default filename; the stack list has no
  "Drop a folder…" empty-state hint (only the panes hint).
- Batch-fuse and bulk-export summaries arrive as notice dialogs — the
  native queueSummaryPresenter styling differs.
- Gestures (two finger pan / zoom) do not match native.
- The source image title label is overlaid on top of the image rather
  than above it as in native, and the output label doesn't exist at
  all.
- The icon in the quit messagebox is a generic folder icon instead of
  the Hyperfocal icon.

Then, deferred until their prerequisites exist:

- **Dirty-rect tile invalidation** once a partial-update producer exists
  (retouch strokes in the Qt shell, item 2): today any epoch bump drops
  every tile, which is right for wholesale changes (progressive
  updates, new fuse) and wasteful only for localized ones — build it
  with the feature that needs it.

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

