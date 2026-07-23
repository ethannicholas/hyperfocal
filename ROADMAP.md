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
libpng / libjpeg-turbo / LibRaw / lcms2 / OpenCV, EXIF via vendored
easyexif) wired into
`Package.swift` via pkg-config. TIFF/PNG/JPEG round-trips verified; the
registration seam moved off `CGImage` to a portable `GrayImage`. macOS
re-verified after the bring-up: `retouch-probe` ALL PASS, synth baselines
unchanged (plane 38.71/38.26, object 41.29), UI suite green — the
`GrayImage` seam is byte-identical on the Apple/Vision path.

System deps (Ubuntu): `swiftlang build-essential pkg-config libraw-dev
liblcms2-dev libjpeg-turbo8-dev libtiff-dev libpng-dev
zlib1g-dev libopencv-dev` (+ `libavformat/avcodec/avutil/swscale-dev
libgif-dev` for the later rocking backend).

Real-frame RAW decode, color, and the as-shot neutral are verified on
Linux (2026-07-19: real DNG stack; DNG round-trip 93 dB; exported
AsShotNeutral closed-loop). Verification used DNGs deliberately — lossy
(High Efficiency) NEFs can't be decoded by any open-source library.
**Windows converts them automatically (2026-07-23)** via the Adobe DNG
Converter (`RawConverter`); the Linux/Wine path is still punted — see
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

1. **Windows CI runner** (plan Phase 1 names Windows CI): ci-gate.sh
   already passes under Git Bash with the environment from
   `Scripts/windows-env.ps1`; needs a GitHub Actions windows job (or
   self-hosted arm64 runner) and possibly Windows-calibrated floors —
   measured margins above the shared floors (2026-07-20): dmap ≥ 0.4 dB,
   pmax 0.25 dB (38.55 vs floor 38.3; the registration gray-path fast
   path shifted the crop by a pixel, which moved pmax from 38.66).
2. **Fusion throughput on modest hardware.** Reference point (82 × 11 MP
   JPEGs, 2-core Windows VM, 2026-07-21, quiet runs): **dmap 173-182 s,
   pmax 132 s** end to end (from 271/181 the day before — the
   registration ¼-scale JPEG gray decode landed: gradient/stats/SIFT
   prep all run on the DCT-domain reduced plane, policy longest ≥
   max(1000, full/5); validation battery in commit 829a67e — 6-frame
   A/B 55.95 dB, jittered-synth truth 45.87 vs 45.81, identical
   bad-frame behavior, same canvas; HYPERFOCAL_REGISTER_FULLGRAY=1
   restores the full decode for ablation). < 2 min end-to-end is the
   bar (measured against commercial stackers on this VM); pmax is 12 s
   from it, dmap ~55 s. Current decomposition:
   - **Registration 46-48 s** = SIFT detect 32 s (82 × ~430 ms at
     1024×683, cvthreads 2 — DoG pyramid dominates, so the 2000-kp cap
     is NOT the wall) + match 14 s (81 × ~165 ms at 2000 kp) + decode/
     gradient glue ~2.5 s (was ~15 before the ¼ decode).
     HYPERFOCAL_SIFT_NFEATURES=1200 measured 2026-07-21: match halves
     (−7 s), detect ~unchanged, synth truth dips 45.87 → 45.52 dB —
     land only with a fresh 45 MP Mac A/B (the 2000 cap is what that
     A/B validated). A genuinely cheaper detector is the bigger prize.
   - **Warp**: 59 s in pmax, 70.8 s in dmap — the ~12 s delta is the
     async spill I/O taxing compute. The loop itself is at its
     practical floor: SIMD8 pair taps landed 2026-07-20 (151.2 dB vs
     old, ~4%); measured cost split at 41 ns/px on `debug-bench warp`:
     weights ~16 (scalar LUT beats vectorized — SIMD8<Int32> conversion
     inits are unspecialized generics, ~250 ns/call), taps ~7,
     homography/divides/clamp/store ~19. Dead ends recorded in
     WarpBench.swift. Don't expect more here without changing outputs.
     Mac Instruments finding (2026-07-21): the stdlib's GENERIC
     pointwiseMin/Max stayed witness-dispatched at -O — 33% of warp
     samples — fixed bit-identically with concrete hfMin/hfMax
     (PortableSIMD), 13.0 → 8.2 ns/px on the Mac bench. **VM
     re-measured 2026-07-22: neutral there** — best 43.4 ns/px on a
     noisy day vs the 40.4-41.4 quiet floor, i.e. unchanged within the
     VM's noise band; consistent with the 2026-07-19 Windows finding
     that concrete-typed pointwiseMin already specialized on Swift
     6.3.3/Windows (the witness-dispatch trap was toolchain-specific).
     The 41 ns/px floor and its cost split stand on the VM.
   - **dmap spill round-trip**: io 41.6 s overlapped under compute
     (fp16, convert free) + render-src 18.3 s reading it back.
     **Byte-reduction is a measured dead end on this VM** (2026-07-21):
     an RGB + 8-bit-alpha slot layout (13 B/px fp32 / 7 B/px fp16,
     bit-identical fp32 round trip proven, alpha exact at the 0/1
     every real source produces) ran a 4-run interleaved A/B — write
     io did NOT drop (~41-48 s regardless of bytes; the VM's write
     path is cache/flush-governed, not bandwidth-proportional),
     render-src reads did scale (−1.3 to −4.4 s), but the strided
     pack cost +3 s of convert and warp inflated +4-9 s alongside it
     (2-core memory-bandwidth interference). Net slightly negative →
     reverted, same bar as the Chebyshev revert. The full change is
     parked in the local `spill-rgb` stash on the Windows VM: its
     −19% fp32 footprint (lossless tier fits smaller disks) may still
     pay on real hardware — measure there before resurrecting.
     HYPERFOCAL_SPILL_FP16=1 (landed) forces the degraded tier on
     tiny stacks for controlled A/Bs (measures ~79.5 dB vs no-spill).
   - **energy 16 s** (post-grid-energy), select/regularize/render ~7 s.
   **45 MP RAW reference** (the real workload: `~/Desktop/Fluorite DNG`,
   10 × 45 MP, dev VM, 2026-07-21): **dmap 295 s** end to end after the
   two changes that stack measured out — (a) registration gray now
   decodes RAW at LibRaw half-size (124 s → 30 s registration;
   old-vs-new outputs 46.61 dB over the aligned intersection, canvas
   within 2 px, zero rejects — validated on the very stack that failed
   flat-1200), and (b) the spill margin is proportional
   (max(2 GB, spill/2)): the flat 2 GB margin let a 7.3 GB fp32 spill
   drive the volume to 97% full where write latency collapses — 2124 s
   vs 469 s forced-fp16, for outputs fp16 matches at **95.9 dB on real
   45 MP content** (far better than the 79.5 dB synth
   characterization). Remaining 45 MP walls, in order: warp ~86 s
   (memory-pressure-inflated: ~2× the bench rate; 4.9 GB peak on
   8 GB), spill io ~48 s + render-src ~33 s (fp16), energy ~28 s,
   decode-blocked ~44 s (LibRaw full demosaic ×1 for fusion —
   prefetch can't fully hide ~11 s/frame on 2 cores), registration
   30 s. Frames-at-once memory (not time) is the likelier next lever
   at this size. Note the byte-reduction dead-end verdict below was
   measured on the 11 MP JPEG stack; at 45 MP the io term is 3× larger
   and fp16 is auto-selected — re-evaluate `spill-rgb` there if spill
   io stays a top bucket on real hardware.
   `compare` now handles two differently-cropped outputs of the same
   scene (Metrics.psnrIntersection) — use it for registration A/Bs.
   Ablation taps: HYPERFOCAL_SIFT_NFEATURES / HYPERFOCAL_SIFT_CONTRAST
   / HYPERFOCAL_REGISTER_MAXSIDE (needs FULLGRAY=1 to ablate above the
   decode scale) + `-v` phase buckets + HYPERFOCAL_REGISTER_DEBUG /
   HYPERFOCAL_DECODE_DEBUG / HYPERFOCAL_SPILL_DEBUG. 45 MP A/B status
   (Mac, Fluorite stack): 1600 bound + 2000 cap verified quality-
   neutral 2026-07-20; **1200 FAILED the same bar at 45 MP**, so the
   bound is a scale floor — max(1200, longest/5) — and the decode
   policy's /5 term mirrors it (a 45 MP JPEG decodes ½ to 2048, then
   boxes to 1638; details in Aligner.openCVRegisterMaxSide's comment
   and the registrationDecodeMinLongest comment). Sampling profilers
   cannot run in the dev VM (hypervisor doesn't virtualize the
   profiling interrupt); on real Windows hardware, wpr + WPA work with
   `swift build -Xswiftc -debug-info-format=codeview -Xlinker /DEBUG`.
   Before touching any per-pixel loop, read PortableSIMD.swift's
   performance contract: cross-file generic calls don't specialize in
   per-file debug builds — that trap cost 55x in the warp until
   2026-07-20.

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

Chrome follows the OS light/dark setting on every platform — the design
rule is that the system appearance is the source of truth and forcing a
scheme is a bug. The shell derives every chrome color from the live
scheme (Main.qml's `theme` object over
`Application.styleHints.colorScheme`; verified in both Windows app
modes); the native app has always taken it from SwiftUI's semantic
colors. Image wells stay a neutral dark surround in both schemes in
both shells — the photo-tool convention, deliberate, not an oversight.

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

1. **Crop rotation cursors** (from Ethan's 2026-07-19 review; not
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
- Trackpad two-finger pan is macOS-only: on Windows/Linux, trackpad
  scrolls arrive as wheel angle deltas (no pixel deltas, incl. through
  VMware), indistinguishable from a mouse wheel, so plain scroll zooms
  there. Pan instead by left-drag (non-retouch) or, in retouch mode,
  middle-drag / Ctrl+drag (the overlay refuses Ctrl presses so the
  pane's drag-pan takes them). ⌥-scroll brush sizing reads whichever
  wheel axis carries the motion (some Windows stacks put Alt+scroll on
  the horizontal axis).

## Release & licensing compliance

A dependency-license audit (2026-07-23) cleared the release model — Hyperfocal
is MIT, the paid Mac App Store / Microsoft Store builds are reproducible from the
public source, and the About box links to the repo. The one blocker was fixed:
**exiv2 (GPL, no linking exception) was replaced with vendored easyexif (BSD-2)**
so the shipped binary is no longer GPL-encumbered. `NOTICE.md` now covers every
shipped dependency per platform (with the verbatim libjpeg-turbo IJG and
libtiff/Berkeley-LZW notices), `licenses/` carries the Apache-2.0/LGPL-3.0/
GPL-3.0/CDDL-1.0 texts, and **LibRaw is used under its CDDL-1.0 arm** (documented
in NOTICE — no LGPL relink burden). The audit found the **macOS build essentially
clean** (Apple frameworks + the permissive Adobe DNG SDK + zlib); all remaining
work is Windows/packaging. Residuals to close before shipping paid builds (each
independently landable):

1. **Bundle the notices into the shipped binaries.** `NOTICE.md` + `licenses/`
   currently live only in the source tree, and both About dialogs point to
   "NOTICE.md in the source distribution." Strict permissive-license attribution
   — and the Qt LGPL duty to ship the GPL+LGPL texts *with* the binary — want them
   local to the app. Add them to the Mac `.app` Resources (via `App/project.yml`,
   then `xcodegen generate`; surface through the About/Help path) and to the
   Windows package. Done = both installed apps carry the notices + license texts
   without needing the repo. (Mac-side needs a Mac session — `xcodegen`/xcodebuild.)

2. **Microsoft Store / MSIX packaging with Qt LGPL-3.0 compliance.** No Windows
   packaging exists yet; build it to this checklist (dynamically-linked Qt makes
   the app's own MIT license fine — LGPL §4 "Combined Works", and §4e
   Installation Information does *not* apply to general-purpose PCs):
   (a) bundle the GPL-3.0 + LGPL-3.0 texts (in `licenses/`) with the package;
   (b) prominent in-app "uses Qt under LGPLv3" notice (done — Qt About);
   (c) host the **exact Qt source** built against, or a written 3-year offer — a
   bare qt.io link is explicitly insufficient per Qt's FAQ;
   (d) ship Qt as replaceable DLLs via windeployqt — **never static-link Qt**;
   (e) do **not** redistribute `qsb.exe` (GPLv3-only build tool) — ship only the
   compiled `.qsb` shaders + the LGPLv3 runtime DLLs;
   (f) because the MSIX copy in `WindowsApps` is locked, **also offer the same
   build off-Store** (direct download) so users can substitute a modified Qt and
   relink — the reproducible-build + public-MIT-source model already provides
   this; state it in the compliance notice. This off-Store route is the
   load-bearing mitigation for the one genuinely-unsettled point (MSIX vs LGPL
   §4(d)(1) DLL-replaceability); also covers the small static `libQt6QmlBuiltins.a`
   fragment (Qt 6.7+). Done = a Store-submittable package meeting (a)-(f) with the
   off-Store build published.

3. **DNG Converter EULA — one-time developer glance, no artifact.** When the free
   Adobe DNG Converter is installed to test the transcode fallback, skim its
   license once to confirm there's no anti-automation or non-commercial clause
   (none expected — Adobe's own CLI manual endorses headless automation, and
   shelling out to it is an established pattern among commercial stackers).
   Hyperfocal neither bundles nor redistributes it and accepts no EULA on the
   user's behalf, so there is **no ongoing obligation and nothing to retain**.
   Done = confirmed once, or consciously skipped (low risk).

4. **Confirm LibRaw's Adobe-DNG-SDK path is off.** The elected license is CDDL-1.0;
   verify the vcpkg `libraw[dng-lossy]` build does not additionally enable
   LibRaw's optional `USE_DNGSDK` integration (which would pull in a separately-
   licensed Adobe path). vcpkg's default does not. Done = confirmed from the
   vcpkg port features / build flags.

## Engine performance

### Metal GPUDMap: zero-copy frame upload (Mac) — blocked on toolchain

The ImageBuffer storage refactor (PixelStorage: page-aligned CoW
storage satisfying the bytesNoCopy contract) was built 2026-07-21 —
whole tree compiled, outputs bit-identical, bench flat — and REVERTED:
it awakens a Swift 6.2.3/Xcode 26 arm64 -O miscompile *class* where
throwing functions touching the wrapper-bearing ImageBuffer return
phantom errors on normal paths (two functions confirmed; ANY wrapper
struct triggers it, even one wrapping [Float]). Full diagnosis,
3-minute repro, and the preserved PixelStorage source:
`Docs/research/2026-07-21-pixelstorage-toolchain-bug.md`. Retried on
Swift 6.3.3 (Xcode 26.5) same day: NOT fixed. UB-hunting ran later the
same day and came back clean (exclusivity-checked -O, TSan ALL PASS,
UncheckedSendable audit); root cause found: swift-frontend's ISel emits
invalid SSA (malformed swifterror PHIs around ObjC error-bridged calls)
— `-verify-machineinstrs` rejects even the PRISTINE tree — and
downstream passes either ICE on it (RegisterCoalescer / RAGreedy) or
silently mis-join, leaving a pixel pointer in the error register x21 on
a normal return. Workarounds were tried the same evening and exhausted
(fuse split, accessor inlining, pass flags, CLI reshaping): the victim
set just moves; details in the doc's Update 3. Blocked on a toolchain
fix — filed as swiftlang/swift#90874 (2026-07-21); watch it, and
re-test each new toolchain with the seconds-fast CLI repro (`fuse
<synth> --method pmax --engine gpu` on the reapplied refactor).

At 45 MP the Metal dmap's `warp` bucket is 25–49 s across runs on the
60-frame Fluorite stack. Two findings from the 2026-07-21 attempt
(implemented, measured, reverted):

- `makeBuffer(bytesNoCopy:)` over `ImageBuffer.pixels` is structurally
  impossible: a Swift `[Float]`'s elements live at offset **32** past
  the storage object's base (verified empirically at every size — the
  ContiguousArrayStorage header), so the base is never page-aligned
  and `malloc_size` on the interior pointer is 0. Zero-copy requires
  ImageBuffer to own page-aligned raw storage instead of `[Float]` —
  a cross-cutting refactor of the engine's central type (or a
  decode-into-MTLBuffer path on the GPU route only).
- The bucket is NOT mostly the memcpy: 727 MB/frame at memory speed is
  ~1–2 s per fuse, yet the bucket swings 25–49 s between identical-code
  runs on the (VM-loaded, memory-pressured) dev Mac — it's dominated by
  system-level pressure servicing the 4–5 GB working set. Re-measure on
  quiet hardware before investing in the refactor; the honest expected
  win is bounded by whatever a quiet run shows above ~2 s.

Do it measured if at all: buckets before/after, output byte-identical,
CPU↔GPU parity ≥ 90 dB. Mac-only benefit (wgpu uploads go through
`wgpuQueueWriteBuffer` — different mechanics).

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

1. Static-link rollout. `Scripts/fetch-wgpu.sh` (pinned tag + per-asset
   sha256, idempotent, macOS/Linux/Git-Bash) and the CI llvmpipe parity
   job landed 2026-07-21; `HYPERFOCAL_WGPU_STATIC=1` links the release
   archive's `libwgpu_native.a` and is proven on macOS (full parity, no
   DYLD_LIBRARY_PATH, zero wgpu load commands — note `-lwgpu_native`
   picks the dylib when both files exist, hence the archive-path link).
   The CI llvmpipe run is green on shared floors with margin to spare
   (first run 2026-07-22: kernels min 112.6 dB, fusion 127.3, dmap
   115.7 — Vulkan joins Metal and WARP as the third backend validating
   the WGSL). Remaining: verify static on Linux (the CI job currently
   runs the dylib + LD_LIBRARY_PATH path) and on Windows (the MSVC
   archives ship import + static libs — pick the static one), then
   fold wgpu out of the CLI-DLL-deployment residual above.

(macOS note, decided 2026-07-21: `HYPERFOCAL_WGPU=1` is legal on macOS
— production Mac builds keep Metal and never set it, but the parity
suite runs through wgpu's Metal backend, so cross-engine WGSL changes
can be gated on a Mac before they reach Windows/Linux. Copy
`libwgpu_native.dylib` beside the built CLI, or point DYLD_LIBRARY_PATH
at `$WGPU_ROOT/lib`, for `debug-wgpu` runs.)

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

