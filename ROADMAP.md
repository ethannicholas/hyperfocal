# Hyperfocal Roadmap

The plan for what's next, in priority order. Each item is self-contained — what,
why, where in the code, and what "done" looks like — so a cold session can pick
one up. **This file is forward-looking only:** shipped work, measurements, and
rejected approaches are *not* recorded here — git history, the README,
`Docs/cross-platform-plan.md`, `Docs/performance.md`, and `Docs/research/` are
the record.

**Regression gates** (re-check before trusting any algorithm change): `swift
build && .build/debug/retouch-probe <synth frames…>` must print `probe: ALL
PASS`; `hyperfocal-cli synth` baselines (default params) are **plane ≈ 38.4 dB
dmap / 38.2 pmax** vs truth. The dmap figure was 38.7 before the focus
measure gained its pre-Laplacian denoise; the synth scenes are noiseless, so
that is the one input class the denoise can only cost — judge DMap changes on
real stacks too (`Docs/research/2026-07-26-dmap-focus-measure.md`). CPU↔GPU
parity is **≥ 90 dB for dmap** (≈ 101 on the synth plane) and **≥ 65 dB for
pmax** (≈ 70). The two bars differ because pixel storage is **f16**: two
engines that agree to better than one f16 ulp still land on different halves,
so ~75–80 dB is the arithmetic ceiling for any value near 1.0, and PMax's
multi-level collapse compounds a few ulps of it. DMap clears 90 because its
output is a weighted average both engines round identically.

There is no longer an exception for the wgpu backend: warped dmap carried a
relaxed **≥ 71** floor while its WGSL kernels were f32 under f16 storage, and
the half-storage port (2026-08-06) took it to **100.1 dB**, back on the same
90 dB bar as everything else. Why the one-seam fix that preceded it failed and
the whole-chain one worked: `WgpuParity.runDMap`.

Anything *below* these bars is drift, not quantization — and the
usual cause is a buffer that should be f32 (an accumulator, or a separable
filter's intermediate) being stored as half. On wgpu there is a second cause
worth knowing: a *store* that narrows with the wrong rounding mode. WGSL's
`pack2x16float` truncates on the D3D12 backend and rounds-to-nearest on
Vulkan/Metal, which is why `h4store` rounds explicitly instead (see
`WgpuEngine`, and `Docs/performance.md` for the 30 dB it costs when it
doesn't). A parity miss on one adapter and not another points here first —
run both with `HYPERFOCAL_WGPU_FALLBACK=1`. `retouch-probe` is macOS-only —
off Apple, gate on the CLI synth→fuse→compare path plus the Qt shell selftest
matrix.

---

## Cross-platform port (Windows/Linux)

The engine, CLI, and Qt/QML shell are **landed at feature parity** on macOS,
Windows, and Linux. Durable strategy and what shipped: `Docs/cross-platform-plan.md`
(+ git history). Remaining:

- **Rocking-animation MP4 on Linux.** GIF exports on all three OSes (giflib,
  via `hf_gif_*`) and H.264 now exports on macOS (AVFoundation) and Windows
  (Media Foundation, `hf_video_*` in `Sources/CImaging/video.cpp`); Linux is
  the one platform left refusing a non-`.gif` filename. The blocker is the
  encoder's licence, not the plumbing — distro FFmpeg builds are configured
  `--enable-gpl` and libx264 is GPL-only, neither of which MIT source + paid
  app-store builds can absorb — which is why both shipped paths use the
  encoder the OS already licenses. **VA-API is the equivalent move** (its
  `libva` is MIT, and the encode is the driver's, not ours); OpenH264 (BSD)
  is the fallback if VA-API's hardware dependence proves too narrow. Either
  goes through the `third-party-deps` gate first. The Swift side is already
  shaped for it: `RockingAnimation.writeH264` is portable and only the
  `#if !os(Windows)` guard on the "choose a .gif" refusal, plus a non-null
  `hf_video_begin`, stand between Linux and the same path Windows takes.
- **Ship the GPU path on Windows and Linux — a packaging decision, no longer
  an engine one.** wgpu is still a build-time opt-in (`HYPERFOCAL_WGPU=1` +
  `WGPU_ROOT`), and neither `Scripts/package-windows.ps1` nor the Linux
  packaging sets it, so every shipped non-Mac build fuses on the CPU while the
  Metal path has had GPU fusion since day one. The engine objections are
  answered: the backend clears the same parity bars as Metal (kernels ≥ 94.9
  dB, dmap 112.9 plain / 100.1 warped, fusion 72.5), and on a discrete GPU it
  is the faster path at the sizes users actually shoot (45 MP dmap fuse 14.2 s
  vs 17.9 s CPU; 100 MP 26.6 s vs 33.7 s). What is left is everything shipping
  a second binary implies, and each item can sink it independently:
  - **Licence + notices.** wgpu-native is MIT/Apache-2.0 dual-licensed, which
    fits, but it ships as `wgpu_native.dll` (~9 MB) or a ~55 MB static archive
    and pulls its own transitive Rust crate graph. Run it through the
    `third-party-deps` skill and land `NOTICE.md` / `licenses/` in the same
    change — `Scripts/gen-notices.py` currently notices no wgpu at all,
    because no shipped binary contains it.
  - **Adapter selection on machines we cannot see.** `usableForAutoSelection`
    already skips software rasterizers (WARP/llvmpipe are slower than the CPU
    path — measured), but a shipped build meets old drivers, hybrid laptops,
    and headless sessions. Decide the fallback contract *before* shipping: a
    failed adapter request must land on the CPU engine silently, and a
    mid-fuse device loss must not fail a user's export.
  - **Static vs dynamic link.** `HYPERFOCAL_WGPU_STATIC=1` drops the DLL from
    the package (verified on Windows, macOS and Linux) at ~55 MB of archive;
    the MSIX size budget and the LGPL-adjacent relinking story in
    `COMPLIANCE.md` both bear on the choice.
  - Done = a Store package whose `--engine auto` picks the GPU on real
    hardware, falls back cleanly without one, and whose notices are complete.
- **HE-NEF decode on Linux/Wine** is still deferred — Windows converts them via
  the Adobe DNG Converter (`RawConverter`), but the Linux/Wine path was punted;
  see `Docs/research/2026-07-19-lossy-nef-linux.md` before revisiting.
- **Qt shell polish toward native parity** (`QtShell/`; the shell self-tests via
  `hyperfocal-qt --selftest <stack-dir> <out.tif> [screenshot.png]`, exit 0 only
  if the export lands, plus the `HFQT_*` env hooks — the flag REQUIRES its two
  paths and now exits 2 with usage without them, because falling through to a
  normal window read as a hung test):
  - **Known non-native behaviors to close** — a running "works, but not the
    native way" list; add to it the moment a new deviation is introduced:
    - Confirms/notices are Qt message boxes (fine on Linux; non-native chrome on
      macOS), and batch/bulk-export summaries arrive as plain notices (the
      native `queueSummaryPresenter` styling differs).
    - No trackpad two-finger pan off macOS (trackpad scroll arrives as wheel
      angle deltas, indistinguishable from a mouse; pan via left-drag, or
      middle-/Ctrl-drag in retouch mode).
  - **Qt↔native presentation parity: remaining reconcile items.** The
    2026-08-01 audit's divergence list was closed 2026-08-01 (git history:
    zoom bar restyle + ×1.5 steps + full level list, export-card buttons,
    fuse-button rules, depth-toggle disable, retouch sidebar, stack-card row
    anatomy + thumbnail placeholder/rounding, empty states, draggable
    sidebar splitter persisting `sidebarWidth`, settings grouping + captions,
    View-menu zoom items, first QML `Accessible.*` hooks — plus the
    stack-thumbnail capacity bug the work surfaced: the shell's fixed 96×96
    copy buffer silently failed once `stackThumbnailMaxSide` grew to 192, so
    Qt stack rows had lost their thumbnails entirely; `hf_stack_thumbnail`
    now reports dimensions on a too-small buffer and the shell resizes and
    retries). The Qt-only extras were reconciled the same day, by decision:
    Cropped-to caption and title-bar dirty marker dropped, Export All Fused
    is a sidebar button (no menu item) on both sides, and the native File
    menu's export item now swaps to "Export Depth Map" in depth mode like
    the Qt shell's; the Qt controls all carry objectNames mirroring the
    native accessibility-identifier vocabulary plus `Accessible.*` where
    text doesn't self-name. Still open:
    - Residual audit scope: dialogs/message boxes were compared at code level
      only, and only the dark scheme was walked visually.
    - Checked and **not** divergent (don't re-walk): slider
      formatting/scales/signs, info-tip delay + icon scoping, algorithm-radio
      layout, crop overlay geometry and cursors, retouch overlay events and
      brush circle, progress overlay content (incl. the batch prefix),
      "(aligned)" title suffix, section collapse behavior, keyboard
      shortcuts, tone slider set, and the doubly-bound shortcuts (undo/redo,
      C, X sit on both a menu `Action.shortcut` and a loose `Shortcut`;
      measured on Windows/Qt 6.10 — the Action wins and fires exactly once,
      in either declaration order, and only *two loose* Shortcuts on one
      sequence go ambiguous. The loose undo/redo pair is also not redundant:
      `sequences:` binds all platform bindings, `shortcut:` only the first).
    Method that worked: `hyperfocal-cli synth` a stack into a frames-only
    directory (keep `ground_truth.tif` out — it ingests as a bad extra
    frame), then `hyperfocal-qt --selftest <frames> <out.tif> <shot.png>`
    with `HFQT_AUTOCONFIRM=1` for the Qt-side window grab; on the native
    side launch with `HYPERFOCAL_UITEST=1 HYPERFOCAL_LOAD_STACK=<container
    path>` (fixtures must live inside the sandbox container) and trigger
    `{"action":"fuse"}` over the uitest command channel, then
    `screencapture` the window. Two traps the close-out hit: the selftest's
    zoom-cycle check compares whole-window grabs, so anything that repaints
    between its two 8× settles fails it — including the macOS native style
    desaturating every accent-colored control when the window deactivates
    (a stray click away from the window mid-run reads as "pixels differ
    after zoom cycle"); and the macOS native style rejects `contentItem`
    customization outright (warnings + fallback), so shared QML must style
    controls via text/font/palette, not custom content items. Worth
    considering whether any part of this can become a gate rather than a
    one-off audit — the formatting drift in particular is comparable data
    on both sides.

## Fusion quality on real stacks

Method: `Docs/research/2026-07-26-dmap-focus-measure.md`. Scoring needs a corpus
of real stacks; one lives outside the repo, with its harness and its per-stack
numbers — ask the maintainer. The score is per-tile sharpness as a percentage of
the best any source frame resolves at that pixel, and the **tile floor** is the
number that moves when depth selection fails.

- **A synth scene with sensor noise.** `hyperfocal-cli synth` renders noiseless
  frames, so the CI PSNR gate is blind to every noise-driven failure — it
  scored a DMap that left a whole background out of focus as fine, and it
  *penalizes* the denoise that fixed it (dmap floor moved 38.7 → 38.2 dB). Add
  a `--noise` option (per-pixel Gaussian in linear light, plus an optional
  chroma-subsampled JPEG round-trip to mimic the reference stacks' artifacts)
  and gate on a noisy scene alongside the clean one. Done: a change that
  degrades real-stack sharpness can no longer pass CI on the synth number.
- **Close the PMax gap — the biggest open quality item.** PMax trails the
  commercial reference on nearly every stack where both tools consume identical
  input pixels (contrast-normalized, worst ≈ −13%), while DMap is at parity on
  the same set. Read `Docs/research/2026-07-27-pmax-debloom-gate.md` first —
  it carries the acceptance criteria (now four, including the source-frame
  floor added 2026-07-27) and the measured dead ends. State of the diagnosed
  piece: the debloom membership is no longer dark-backdrop-only (`debloomMasks`
  unions the near-black proof with an open-background proof: border-connected,
  never-focusing, and FLAT — see the doc's flatness-gate section), and track B
  in open-background cells is sign-aware: the merge picks the darkest or
  brightest unfocused extreme per cell, whichever lands closer to a push-pull
  clean field. On the bright-backdrop silhouette that closes about half the
  gap to the reference — matching it at 6 px, with zero source-frame-floor
  violations and top-1% within 0.03% — and every other corpus stack stays
  bit-identical. Open, in order:
  Shipped 2026-07-28 (see
  `Docs/research/2026-07-28-pmax-band-leakage-smoothed-selection.md` and the
  commits around it): smoothed selection at every band level + the exact
  Burt expand, with a source-envelope discipline (output-space clamp,
  per-pixel never-focused membership, near-black texture veto) — the
  blown-text veil closed from +33 to +19.5 p99 over the sharp source frame,
  C1–C4 + re-anchored C2 all PASS, and all three engines carry the full
  configuration (wgpu kernel parity ≥ 104 dB, fusion 69.6 dB vs the 60 dB
  bar; Metal 60.1 dB on a real stack — tie-flip bounded as documented).
  What remains here, in order:
  - **The rest of the silhouette transition (10–30 px).** The reference
    matches the subject-sharp source frame's own edge tail there. A coarse-
    levels-only frame-consistency mechanism (regularized frame map + selective
    re-decode of the map's frames) was built and measured — the map and the
    second pass work, but governing only the gated levels while fine levels
    stay max-of-N mixes inconsistent selections and does not pay; the doc's
    final section records what to keep and what not to retry. The real fix is
    frame-governed selection at EVERY level in background regions — rendering
    the background the way DMap renders everything, from a regional frame
    decision, while PMax's per-coefficient selection keeps the subject.
    Designed 2026-07-28:
    `Docs/research/2026-07-28-pmax-hybrid-background-renderer.md` — the
    decision goes engine-internal (the prototype's frame map, NOT the app's
    DMap peer, for app/CLI parity), governance is all-levels-or-nothing, and
    acceptance criteria are now six (adds a both-sided source-envelope check
    and engine parity). **Implemented 2026-07-28 (same doc, final section):
    env-gated, default off** — `PyramidFusion.governBackground` behind
    `Options.backgroundGovernanceRadius` (0 = off, bit-identical;
    `HYPERFOCAL_PMAX_GOV_RADIUS=6` is the candidate surface; CPU-only).
    Block-committed frame map from a streaming energy table, image-space
    convex composite, scoped to the flatness gate's textured complement.
    At radius 6 the harness reads C1–C4 exactly unmoved and C5 improved
    both-sided on both stacks (fabrication 25→11 high on defocused foliage,
    deadening 27→6 low on the dark garden) but NOT flipped — and **manual
    review failed the candidate outright** (backgrounds brighten above the
    reference: governed low frequencies replace the darkest-base photometry;
    subject-adjacent blur patches from the widened membership; sharp
    sub-content erased inside median-passed components — all four invisible
    to the six criteria; see the doc's final section). The machinery stands,
    the calibration does not. Next attempt: govern fine texture over shipped
    low frequencies, conservative subject mask, per-cell focusing veto. The
    two harness instruments the review demanded now exist (C7
    background-luminance regression fence, C8 two-leg fine-detail retention
    at 32 px cells — private corpus, calibrated so defaults pass everywhere
    and the eye-failed candidate fails on exactly the stacks and defects
    the review named; instrument notes in the harness docstrings). Ship-on
    still needs the C5 flip judged under all eight criteria, the dual-UI
    surface, and the GPU story.
  - **Textured defocused backgrounds are excluded on purpose.** The
    clean-field mechanism deadens bokeh/out-of-focus mottle (measured
    0.3–0.7× the liveliest source frame), so the flatness gate scopes it
    to flat backdrops. Lifting that needs a track B that preserves
    single-frame coherent texture — likely the same regional-consistency
    machinery.
  - PMax also noise-amplifies defocused backgrounds (max-of-N selection,
    measured 2–4× above every registered source frame on one stack); a
    keep-darkest variant cleaned it but was scoped out along with the
    texture problem, and the same machinery would fix both honestly.
  Second thread, now diagnosed: the widest
  per-stack PMax deficit (≈ −13% normalized, both registration directions)
  turned out to be mostly the reference's output sharpening — its render
  exceeds the best *registered source frame* on two-thirds of tiles (energy
  its sources don't contain), and a plain unsharp mask on our render flips
  the comparison to +20% — plus one narrow real weakness worth keeping: in
  tiles of weak, near-noise-floor speckle, our max-selection lets other
  frames' noise dilute the single frame that carries coherent detail (fused
  lands at 0.7–0.9× the best source frame there; DMap holds 1.0–1.07). The
  measurements and per-stack numbers live with the private corpus README.
- **Close the remaining DMap gaps.** Against the commercial DMap we are at
  parity on the small stacks (contrast-normalized, within ±5% either way) and
  well ahead on the high-resolution raw ones — though that margin plausibly
  includes raw *decode* differences, not just fusion, so do not bank it. The
  stack that looked behind "by a margin wide enough to be a distinct bug" was
  diagnosed 2026-07-28 and is **not a bug**: the commercial tool renders at the
  *last* frame's geometry while we render at the mid frame's, and the corpus
  metric's unregistered reference holds each region's detail at whichever
  geometry the resolving frame had — so on a hard-breathing stack every
  late-resolving edge region scored us against detail our correct registration
  deliberately moved (verified on a second stack; details and the corrected
  method in the corpus README). What survived the diagnosis, in order:
  - **Defocused-background texture flattening — the real lead.** Where no
    frame ever focuses, our depth plane is noise, and blending 2-3 frames of
    decorrelated bokeh mottle averages real scene texture away (measured
    0.36× the liveliest registered source frame, vs the reference render's
    honest 0.95×). Not tuning: peak-concentration, noise-floor, guided/median
    radius, blend radius, and (since-removed) despill sweeps all move it ≤1
    point. The fix is
    regional frame *commitment* in no-confidence regions — the same
    frame-governed-background direction as the PMax hybrid renderer
    (`Docs/research/2026-07-28-pmax-hybrid-background-renderer.md`), which is
    why the two should be designed together.
  - **A fully-defocused end frame can register as a scale outlier** (7% step
    against its neighbor where every other step is ≤3%; nothing sharp to lock
    onto) without `--auto-exclude` noticing. It shrinks the common-coverage
    canvas ~2% and lets front-depth regions render from a misplaced frame.
    No visible artifact tied to it yet — treat as a registration-robustness
    lead, and a candidate new check for auto-exclude (adjacent-step scale
    continuity).
  - The remaining "behind" stack was re-derived 2026-07-28 against a
    registered reference: **same artifact — we actually win its mean and
    tile-p10**. With that, every reference-based DMap deficit in the corpus
    is explained; the scoring harness gained a registered-reference mode and
    a geometry-mismatch flag so the artifact cannot recur silently. DMap's
    only remaining quality item is the texture-flattening lead above. (The
    same registered run confirms the PMax background gap is real, which is
    the hybrid-background design note's problem, not this item's.)
- **Verify the regularization radii above the reference resolution.**
  `DMapFusion.regularizationScale` scales `medianRadius`/`guidedRadius` by the
  frame diagonal against a 9780 px reference but is **clamped to 1**: it only
  ever scales down, because every reference stack is under 2 MP and the
  large-frame direction was untestable here. The physical argument (defocus
  artifacts scale with the frame) says a 100 MP stack wants radii larger than
  the 45 MP defaults. Measure on a real high-resolution stack before removing
  the clamp — and note `medianRadius` is a user-facing slider persisted in
  projects, so its effective meaning is already resolution-relative.

## UI Improvements

- Improve the experience of opening a project. It can take quite a while to load;
  there should be an indicator in the UI that it is working on it beyond "most of the
  menu items are disabled".
- Improve the experience of saving a project. It currently beachballs for several
  seconds with a big project.

## Release & licensing compliance

The 2026-07-23 dependency-license audit cleared the release model (MIT source,
reproducible paid app-store builds); the one blocker was fixed (GPL exiv2 →
BSD-2 easyexif), `NOTICE.md` + `licenses/` are complete, and LibRaw is used under
its CDDL-1.0 arm. The Windows package now exists and meets the Qt LGPL-3.0
checklist, and both shells bundle the notices with a populated Third-Party
Notices viewer linked from the About dialog (`Shell::noticesMarkdown` /
`App/Sources/NoticesWindow.swift`). The one residual before shipping paid
builds:

1. **Microsoft Store / MSIX submission.** `Scripts/package-windows.ps1` now
   produces a submission-ready package end to end, with no flags: the payload,
   the staged layout, generated logo assets, and `AppxManifest.xml` carrying the reserved
   Store identity (`EthanNicholas.Hyperfocal`, baked into the script — public
   values, not credentials). Verified 2026-08-05 on x64: stages 213.2 MB /
   1468 files, packs to an 83.3 MB `.msix`, and `Add-AppxPackage -Register` on
   the loose layout installs and launches under the real identity at version
   `1.0.0.0` (the Store requires the 4th version part to be 0, so the commit
   count stays the About box's build number). The package is deliberately
   **unsigned** — Partner Center signs Store submissions, so no code-signing
   certificate is involved. Remaining, and all of it outside this repo:
   - **WACK: run 2026-08-05, overall WARNING — 22 PASS, 1 FAIL, 1 WARNING.**
     Re-run after any packaging change (the kit is at `C:\Program Files
     (x86)\Windows Kits\10\App Certification Kit\`, and every invocation,
     including `/?`, requires an **elevated** shell):
     ```
     appcert.exe reset
     appcert.exe test -appxpackagepath dist\Hyperfocal-<ver>-<arch>.msix \
                      -reportoutputpath wack.xml
     ```
     Point it at the **.msix**, not `-packagefullname` of a dev-registered
     layout: the first attempt did the latter and 22 of 24 tests "failed" with
     *"The manifest file for this app package could not be found"* — a package
     registered from loose files has no packaged manifest to extract, so the
     tests ran with no input. That was a broken method, not a result. Note
     `-apptype` does **not** apply here at all; it selects between `desktop`
     and `desktopdevice` for INSTALLER-based apps and is documented as "Not
     needed for Store app" (the kit detects ours as type *Centennial*).
     The two non-passes, both assessed and neither believed to be a real
     defect — but recheck rather than assume if certification bounces:
     - **FAIL, "Blocked executables."** Flags `CreateProcessW` /
       `ShellExecuteW` imports in `Qt6Core.dll`, `Foundation.dll` and
       `platforms\qwindows.dll`, plus "blocked executable" string matches for
       `cmd`/`reg`/`cdb`/`csi`. The string matches are case-scrambled
       substrings (`CSi`, `reG`, `Reg`) — i.e. fragments inside unrelated
       strings, not references to those tools — and they also fire on
       `d3dcompiler_47.dll` and `dxcompiler.dll`, which are Microsoft's own
       redistributables copied unmodified from the Windows SDK and cannot be
       changed. The process-launch imports are real and legitimate: Qt has
       QProcess, Swift Foundation has Process, and the app genuinely shells
       out to the Adobe DNG Converter — which is why the manifest declares
       `runFullTrust`. This test's restrictions target UWP; full-trust
       Centennial apps are permitted to launch processes. If certification
       does object, `appcert.exe finalizereport -reportfilepath <xml>` is the
       waiver path (a `test` exit of 1, rather than the 0 we got, is the kit
       asking for it).
     - **WARNING, "DPIAwarenessValidation" — a static-analysis artifact.**
       The report says the app "is not DPI Aware" because `hyperfocal-qt.exe`
       declares no `dpiAwareness` in its embedded manifest (it carries only
       `Scripts/windows-utf8.manifest`'s `activeCodePage`) and imports no DPI
       API. But Qt 6 sets Per-Monitor v2 at startup through a *dynamically
       resolved* `SetProcessDpiAwarenessContext`, which a static import scan
       cannot see. Measured on the running packaged process:
       `GetProcessDpiAwareness` returns **2 = PROCESS_PER_MONITOR_DPI_AWARE**.
       So the app is DPI-aware in fact. Optional hardening, not yet done:
       add `<dpiAwareness>PerMonitorV2</dpiAwareness>` to
       `Scripts/windows-utf8.manifest` so it applies before process start and
       the warning goes away — Qt honours an existing manifest declaration
       rather than overriding it. **Validate on a scaled display**; the
       machine this was measured on runs at 100%, so a DPI change could not
       be judged there.
   - Complete the listing in Partner Center (screenshots — see item 2 —
     description, age rating, privacy policy at
     http://ethannicholas.com/hyperfocal/privacy.html) and submit.
   - An arm64 package is a separate build on arm64 hardware; the script picks
     its architecture from `PROCESSOR_ARCHITECTURE` and names the output
     accordingly, so nothing in it needs changing.

   Note the shipped build is still **CPU-only**: wgpu is opt-in behind
   `HYPERFOCAL_WGPU=1` and `Scripts/package-windows.ps1` does not set it, so no
   GPU fusion path reaches Store users. The engine reason for that is gone —
   the half-storage port (2026-08-06) put the backend on the same parity bars
   as Metal and made it the faster path on real hardware (a 45 MP dmap fuse
   14.2 s vs 17.9 s, 100 MP 26.6 s vs 33.7 s) — so what remains is a shipping
   decision, tracked as its own item below.

   The LGPL-3.0
   checklist the package was built to is settled and enforced in the script —
   Qt ships as separate (never static) DLLs, the GPLv3-only
   `qsb`/`lupdate`/`lrelease` tools are asserted absent, and the GPL-3.0 +
   LGPL-3.0 texts plus the written 3-year source offer ride in `COMPLIANCE.md`.
   **The §4(d)(0) relinking right is satisfied by source** — the app is MIT and
   public with a reproducible build, so a user rebuilds against their own
   modified Qt. That is also what covers the small static `libQt6QmlBuiltins.a`
   fragment (Qt 6.7+), which no DLL-replacement story ever could.
   **There is no off-Store binary, and there will not be one:** Hyperfocal ships
   through the Mac App Store and Microsoft Store, or from source. The script
   emits only the staged layout and the `.msix`; it deliberately no longer
   archives the layout, because a `Hyperfocal-<version>.zip` in `dist/` reads as
   a downloadable release. Never propose a side-loadable build to satisfy an
   LGPL obligation.

2. **Store-listing media: the language sweep and the Windows side.**
   `Scripts/store-media.py` captures Mac App Store media in one shot — the
   fusion-workflow app-preview video (1920×1080 H.264 30 fps with the silent
   stereo AAC track App Store Connect requires, time-compressed into the
   mandatory 15–30 s if fusion runs long) and retouch-mode screenshots at an
   accepted size (default 2560×1600; 2880×1800 is unreachable while a Dock is
   showing because macOS clamps windows to the visible frame). It drives the
   app over the UITestSupport command channel (`set-window`/`set-zoom`/
   `set-retouch`/`set-sections`/`get-geometry`, `HYPERFOCAL_WINDOW`), and a
   CGEvent helper walks the real pointer so the retouch crosshair + brush
   circle land in the shot. Stack folder and image coordinates are operator
   parameters (private corpus — kept out of the repo). A run defaults to
   every catalog language, one localized app session each (`-AppleLanguages`
   for the app catalog + `HYPERFOCAL_LANG` for the shared layer; `--lang`
   restricts it for testing). English and German are verified; remaining:
   - Run the full sweep and eyeball the results — especially the wide
     languages (de, ru) — for clipped layouts in the captured framings.
   - **The Windows/Qt equivalent is written but UNVERIFIED — it has never
     produced a screenshot.** `QtShell/CommandChannel.h` (a file-based command
     channel, inert unless `HFQT_COMMAND_DIR` is set) plus
     `Scripts/store-media.ps1`. The channel speaks the same vocabulary as the
     macOS one (`set-window`/`set-zoom`/`set-slider`/`set-sections`/
     `set-retouch`/`get-geometry`, plus `set-depth`, `set-hover` and `grab`),
     so one capture recipe describes both shells. Microsoft Store wants PNG
     screenshots ≥ 1366×768 (up to 3840×2160, ≤ 10 per listing) and optional
     1920×1080 MP4 trailers. What is known to work: launch, ingest, and
     commands executing against the staged package. What is untested:
     everything from `fuse` onward — the fused/depth/retouch framings, the
     brush circle via `set-hover`, and the language sweep. Finish by running
     `Scripts\store-media.ps1 -Frames <stack> -Out <dir> -Lang en` and
     working through what breaks. Three traps already paid for:
     - Capture from the **staged package** (`dist\Hyperfocal-*\`), which the
       driver now prefers. A dev build out of `QtShell\build*\` resolves none
       of its DLLs unless `Scripts\windows-env.ps1` is dot-sourced in the
       *launching* shell, and the failure is an instant exit with 0xC0000135,
       not a message. The shell is a GUI-subsystem binary, so its own logging
       reaches no console either — hence the channel's `ready` marker file.
     - Windows are clamped to the desktop work area, so 1920×1080 is
       unreachable on a 1920×1080 screen (measured: 1920×1061 with a taskbar)
       — the same clamp the Dock imposes on the macOS driver. Default is
       1600×900 pt; `get-geometry` reports `availW`/`availH`.
     - No screen recorder or cursor helper is needed, unlike the macOS side:
       grabs come from the app's own `grabWindow()`, and the brush circle is
       a QML overlay that a grab captures, so `set-hover` stands in for
       parking a real pointer. A trailer would need a real encoder path and
       is deliberately not attempted — Store trailers are optional.

## Engine performance

Throughput breakdowns, measured dead-ends, ablation taps, and the per-pixel
specialization contract: `Docs/performance.md` — read it before touching a hot
loop or re-attempting a parked optimization.

### Memory (characterized 2026-07-26; instruments are permanent)

Tooling: `HYPERFOCAL_MEMLOG=1` logs phys_footprint deltas at every model
retention milestone; `EngineStats` splits a footprint into Metal-held vs
malloc-held; `retouch-probe --memprofile <frames…>` runs the whole app-layer
lifecycle headless on real frames and prints the marks;
`retouch-probe --memdecode <frames…>` isolates decode-cache behavior. Measured
on a 43-frame 46 MP NEF stack: fused-idle ≈ 5–6 GB of deliberate full-res
retention (ledger in the instrumentation commit), transients to ~11 GB while
the background secondary runs, and ~5.9 GB surviving project close with every
model property provably empty. That residual is NOT an app leak; its
composition drives the two items below.

**Those figures predate f16 storage** (pixels are 8 B/px now, not 16). The
CLI A/B on a 12 MP × 17 synth stack measured ~25 % off peak footprint, not
50 %, because decode buffers, the scalar f32 planes, and the Metal/OS baseline
don't scale with pixel storage — so re-run `--memprofile` on the 46 MP NEF
stack before quoting a new ledger.

- **Return the Metal allocator's memory (~2–2.6 GB).** MTLDevice retains freed
  buffer memory for the process lifetime — measured flat across project close
  with zero live MTLBuffer references (`EngineStats.metalAllocatedBytes`).
  Fix: back the engine's frame-sized buffers with our own page-aligned
  vm_allocate'd memory via `makeBuffer(bytesNoCopy:deallocator:)` in
  `MetalEngine.makeBuffer(floats:)` so freeing genuinely returns pages.
  Done = post-close `metalAllocatedBytes` near zero and phys_footprint drops
  accordingly in `--memprofile`, with fuse wall-clock unchanged (buffer
  creation is not on the hot path, but measure — the doc's loaded-machine
  rule applies).
- **RAW-decode pipeline cache (~2.3 GB, Apple's).** A bounded working set —
  flat whether 10 or 43 distinct NEFs are decoded (`--memdecode`), partly on
  ImageIO's own internal Metal device where `EngineStats` can't see it, and
  only partially reclaimed by malloc pressure relief. Options to investigate,
  each measured with `--memdecode`: `kCGImageSourceShouldCache(Immediately)`
  = false on the decode paths in `ImageFile`, scoping decodes to a discardable
  context, or accepting it as the cost of Apple's RAW engine and documenting
  it. Do not chase it below ~2 GB without checking decode throughput — the
  cache exists for a reason.
- **Depth-map export precision.** `DMapFusion.depthImage` now returns an f16
  `ImageBuffer` like everything else, so a 16-bit depth-map export resolves
  ~2048 levels over its top octave instead of 65535. Far above what a stack can
  express (frame counts are in the tens) and `resultDepth` — the f32 plane
  projects persist and retouch merges into — is untouched, so this is only a
  concern if depth maps get used as external range data. If that becomes a use
  case, export depth straight from `resultDepth` to 16-bit fixed point and skip
  the image entirely.

- **Serve retouch source loads from the retained warped-frame spill.** The
  background PMax generation now streams the DMap primary's `WarpedFrameCache`
  instead of re-decoding (measured: concurrent RAW decode ran a pmax fuse ≥7×
  slower end-to-end, because Apple's RAW engine degrades under exactly the
  concurrency retouch's on-demand `loadAligned` produces). Retouch itself still
  re-decodes: every frame-source switch is a full RAW decode + warp
  (`RetouchSession.selectSource` → `loadAligned`, plus `prefetchNeighbors`).
  Serving those from the same cache would make frame switching near-instant and
  remove the app's remaining self-contention — at the cost of keeping the
  multi-GB spill alive for the whole retouch session (it skips itself on tight
  disks; the decode path stays as the fallback).
  Decide the lifetime policy (session-long vs release-on-low-space) before
  wiring it.
- **Symmetric spill for a PMax primary.** The reuse above only helps the
  DMap-primary direction: a PMax primary spills nothing, so its background
  DMap secondary re-decodes the stack (twice the exposure to the same
  contention — untimed so far, user report pending). The pyramid engines
  consume warped frames but never write a spill; adding `retainSpill` there
  (write-through during the accumulation pass, like GPUDMap's pass 1) would
  give the DMap secondary the same free ride.

- **Fusion throughput on modest hardware** — hit the **< 2 min end-to-end** bar
  on the 2-core reference (currently ~175 s dmap / ~132 s pmax at 11 MP; ~295 s
  dmap at 45 MP). The biggest remaining prize is a **cheaper feature detector**
  (SIFT's DoG pyramid dominates registration). Breakdown + what's been tried:
  `Docs/performance.md`. On x64 desktop hardware the bar is already met with
  room to spare, which promotes the detector from "biggest remaining prize" to
  the **only** one of consequence there: the x86-64 ISA baseline (2026-07-29)
  cut fusion to 5.5–7.9 s at 12 MP while registration stayed put at ~6.7 s, so
  registration is now **51 % of the fastest configuration's wall clock**. It is
  the one phase the ISA change could not help — OpenCV already dispatches SIMD
  at runtime — so nothing short of a different detector moves it.
- **Metal GPUDMap: zero-copy frame upload (Mac)** — blocked on a Swift toolchain
  miscompile (filed swiftlang/swift#90874). Re-test each new toolchain with the
  seconds-fast CLI repro in `Docs/research/2026-07-21-pixelstorage-toolchain-bug.md`.
  Mac-only benefit (wgpu uploads use a different mechanism); do it measured —
  buckets before/after, output byte-identical, parity ≥ 90 dB.
- **RAW decode is the fusion bottleneck — the next real throughput win.** With
  both fusion paths on the GPU, decode dominates everything else. Measured on a
  *quiet* machine (Azurite, 63 DNGs at 8076x5237, M1 Pro, two interleaved reps):

  | method | GPU fuse | CPU fuse | GPU compute inside the fuse |
  |---|---|---|---|
  | pmax | 32.9-43.8 s | 62.1-62.6 s | **0.07-0.65 s** |
  | dmap | 47.7-51.8 s | 74.5-76.4 s | **~1.2 s** |

  PMax on the GPU is 31 s decode-wait + 1.7-8.3 s upload + **0.1 s** of actual
  kernel time; DMap adds 10-14 s spill-write and ~7 s spill-read on top of ~21 s
  decode-wait. Kernel optimization has nothing left to give at this stack size —
  the targets are (a) RAW decode throughput (LibRaw/CIRAW, ~0.4 s/frame), (b) the
  upload path, and (c) for DMap, whether the frame spill still pays now that it
  costs ~17-21 s against a ~21 s re-decode. **Read `Docs/performance.md` first**,
  and re-measure before trusting any of this: an earlier run of the same
  benchmark on a loaded machine reported pmax GPU at 171 s vs CPU 135 s and
  inverted the ordering entirely.
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
