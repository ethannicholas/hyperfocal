# Hyperfocal Roadmap

The plan for what's next, in priority order. Each item is self-contained — what,
why, where in the code, and what "done" looks like — so a cold session can pick
one up. **This file is forward-looking only:** shipped work, measurements, and
rejected approaches are *not* recorded here — git history, the README,
`Docs/cross-platform-plan.md`, `Docs/performance.md`, and `Docs/research/` are
the record.

**Regression gates** (re-check before trusting any algorithm change): `swift
build && .build/debug/retouch-probe <synth frames…>` must print `probe: ALL
PASS`; `hyperfocal-cli synth` baselines (default params) are **plane ≈ 38.7 dB
dmap / 38.3 pmax**, **object ≈ 41.3** vs truth; CPU↔GPU parity **≥ 90 dB** both
methods (≈ 114 dmap / 106 pmax on the synth plane). `retouch-probe` is
macOS-only — off Apple, gate on the CLI synth→fuse→compare path plus the Qt
shell selftest matrix.

---

## Cross-platform port (Windows/Linux)

The engine, CLI, and Qt/QML shell are **landed at feature parity** on macOS,
Windows, and Linux. Durable strategy and what shipped: `Docs/cross-platform-plan.md`
(+ git history). Remaining:

- **Windows CI runner.** `Scripts/ci-gate.sh` already passes under Git Bash with
  the `Scripts/windows-env.ps1` environment; needs a GitHub Actions Windows job
  (or a self-hosted arm64 runner), possibly with Windows-calibrated PSNR floors
  (margins above the shared floors are thin: pmax ~0.25 dB).
- **Rocking-animation export on non-Apple.** `RockingAnimation.write` throws off
  Apple — needs the FFmpeg/giflib backend (Ubuntu deps for it:
  `libavformat/avcodec/avutil/swscale-dev libgif-dev`).
- **Capture-time EXIF *stamping* in `SynthStack`** (ImageIO-only today; needed
  off Apple for session-split tests).
- **HE-NEF decode on Linux/Wine** is still deferred — Windows converts them via
  the Adobe DNG Converter (`RawConverter`), but the Linux/Wine path was punted;
  see `Docs/research/2026-07-19-lossy-nef-linux.md` before revisiting.
- **Qt shell polish toward native parity** (`QtShell/`; the shell self-tests via
  `hyperfocal-qt --selftest` with `HFQT_*` env hooks):
  - **Crop rotation cursors** matching the macOS sector-oriented rotate cursors
    (Qt has no built-in rotate cursor — needs custom cursor images quantized to
    8 sectors, like `ContentView.swift:2093-2103`).
  - **Known non-native behaviors to close** — a running "works, but not the
    native way" list; add to it the moment a new deviation is introduced:
    - Confirms/notices are Qt message boxes (fine on Linux; non-native chrome on
      macOS), and batch/bulk-export summaries arrive as plain notices (the
      native `queueSummaryPresenter` styling differs).
    - No trackpad two-finger pan off macOS (trackpad scroll arrives as wheel
      angle deltas, indistinguishable from a mouse; pan via left-drag, or
      middle-/Ctrl-drag in retouch mode).

## UI Improvements

- Improve the experience of starting retouching. Right now it simply freezes the
  UI for up to several seconds before being ready. If we can't speed it up, we need
  a spinner or similar progress indicator.
- Improve the experience of opening a project. It can take quite a while to load;
  there should be an indicator in the UI that it is working on it beyond "most of the
  menu items are disabled".
- Improve the experience of saving a project. It currently beachballs for several
  seconds with a big project.
- Clean up the tooltips. They currently read like they were written by an LLM that
  was very proud of what it had built and wanted everybody to understand all of the
  details. They need to be much tighter and focused on what the user actually needs
  to understand.

## Release & licensing compliance

The 2026-07-23 dependency-license audit cleared the release model (MIT source,
reproducible paid app-store builds); the one blocker was fixed (GPL exiv2 →
BSD-2 easyexif), `NOTICE.md` + `licenses/` are complete, and LibRaw is used under
its CDDL-1.0 arm. The macOS build is essentially clean; the remaining work is all
Windows/packaging. Residuals before shipping paid builds (each independently
landable):

1. **Bundle the notices into the shipped binaries.** `NOTICE.md` + `licenses/`
   live only in the source tree, and both About dialogs point to "NOTICE.md in
   the source distribution." Strict permissive-license attribution — and the Qt
   LGPL duty to ship the GPL+LGPL texts *with* the binary — want them local to
   the app. Add them to the Mac `.app` Resources (via `App/project.yml`, then
   `xcodegen generate`; surface through the About/Help path) and to the Windows
   package. Done = both installed apps carry the notices + license texts without
   the repo. (Mac side needs a Mac session — `xcodegen`/xcodebuild.)

2. **Microsoft Store / MSIX packaging with Qt LGPL-3.0 compliance.** No Windows
   packaging exists yet; build it to this checklist (dynamically-linked Qt keeps
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
   §4(d)(1) DLL-replaceability), and also covers the small static
   `libQt6QmlBuiltins.a` fragment (Qt 6.7+). Done = a Store-submittable package
   meeting (a)–(f) with the off-Store build published.

3. **DNG Converter EULA — one-time developer glance, no artifact.** When the free
   Adobe DNG Converter is installed to test the transcode fallback, skim its
   license once to confirm there's no anti-automation or non-commercial clause
   (none expected — Adobe's own CLI manual endorses headless automation).
   Hyperfocal neither bundles nor redistributes it and accepts no EULA on the
   user's behalf, so there is **no ongoing obligation and nothing to retain**.
   Done = confirmed once, or consciously skipped (low risk).

4. **Confirm LibRaw's Adobe-DNG-SDK path is off.** The elected license is
   CDDL-1.0; verify the vcpkg `libraw[dng-lossy]` build does not additionally
   enable LibRaw's optional `USE_DNGSDK` integration (a separately-licensed Adobe
   path). vcpkg's default does not. Done = confirmed from the vcpkg port flags.

## Engine performance

Throughput breakdowns, measured dead-ends, ablation taps, and the per-pixel
specialization contract: `Docs/performance.md` — read it before touching a hot
loop or re-attempting a parked optimization.

- **Fusion throughput on modest hardware** — hit the **< 2 min end-to-end** bar
  on the 2-core reference (currently ~175 s dmap / ~132 s pmax at 11 MP; ~295 s
  dmap at 45 MP). The biggest remaining prize is a **cheaper feature detector**
  (SIFT's DoG pyramid dominates registration). Breakdown + what's been tried:
  `Docs/performance.md`.
- **Metal GPUDMap: zero-copy frame upload (Mac)** — blocked on a Swift toolchain
  miscompile (filed swiftlang/swift#90874). Re-test each new toolchain with the
  seconds-fast CLI repro in `Docs/research/2026-07-21-pixelstorage-toolchain-bug.md`.
  Mac-only benefit (wgpu uploads use a different mechanism); do it measured —
  buckets before/after, output byte-identical, parity ≥ 90 dB.
- **wgpu static-link rollout.** Both fusion paths run on the wgpu/WGSL backend
  (opt-in `HYPERFOCAL_WGPU=1`; validated on WARP + llvmpipe, real-hardware
  speedups still unmeasured — the dev VM has no hardware DX12).
  `HYPERFOCAL_WGPU_STATIC=1` links `libwgpu_native.a` and is proven on macOS.
  Remaining: verify the static link on **Linux** and **Windows** (pick the
  static lib from the MSVC archives), then fold wgpu out of the CLI-DLL
  deployment concern.
- **Research-informed fusion follow-ons** — full findings, evidence, sources, and
  refuted claims: `Docs/research/2026-07-12-focus-stacking-research.md` (consult
  before revisiting). The regularizer is `DepthRegularize.swift` (ablation
  switches `HYPERFOCAL_GUIDED_NO_TIER2` / `_NO_TIER2_MASK` / `_FIXED_EPS`); judge
  each idea against the specular-bokeh mineral stack (fluorite on marble, subject
  sharp mid-stack, tail focused past it — full-res NEFs in `~/Desktop/Fluorite`).
  Candidates:
  - **Focus-measure upgrades**: Ring Difference Filter kernel (local accuracy +
    non-local noise robustness); multi-scale dilated Laplacian; variance or
    Tenengrad as a noise-robust *complementary gate* (Laplacian degrades above
    ~30 % saturation — i.e. on speculars).
  - **Render**: energy-weighted averaging *only inside low-confidence regions*
    (must stay regional — global energy-weighting sacrifices sharpness); reserve
    pyramid fusion for flagged overlap/discontinuity regions (an automated
    "dmap base, pmax over the hard regions" hybrid).
  - **Stronger regularization, only if artifacts demand it**: aggregate the focus
    *cost volume* before argmax (RDF-style, or separable 3D-WLS — tridiagonal 1-D
    solves, plausibly GPU-feasible at grid resolution). One bounded behavior to
    watch: where the guide is flat across a confidence rim, ramps meet plateaus
    with a seed-side bias (probe bounds it < 4 frames on the synthetic ramp); a
    2-pass iteration is the flagged remedy if a real stack shows it.
  - **Open (unresearched)**: fusion-quality metrics (Q_AB/F, MI, SSIM-variants)
    for the regression suite, and Core ML-portable 2020+ fusion/DfF networks —
    each needs a dedicated pass; PSNR-vs-synthetic-truth is the gate meanwhile.
