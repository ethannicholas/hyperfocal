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

**One exception, and it is the wgpu backend only:** warped dmap on wgpu is
gated at **≥ 71**, not 90 (`debug-wgpu --dmap-warp-floor`, ≈ 74 measured).
That is not a property of warped frames — CPU↔**Metal** warped dmap clears 90
comfortably (≈ 103). It is the unfinished f16 port below: wgpu's WGSL kernels
are still f32 while storage is f16, so it alone warps in f32 and stores
through half, and where its result straddles a rounding boundary the argmax
flips a frame index. The bar should return to 90 when that port lands.
Derivation, the evidence that it is quantization rather than drift, and a
refuted one-seam fix: `WgpuParity.runDMap`. Re-measured 2026-07-28 on a
discrete GPU through wgpu's Vulkan backend: **74.0 dB, unchanged to the
decimal** from the software-rasterizer figure the floor was set against. The
number is adapter-independent, which is the strongest evidence yet that it is
f16 quantization rather than a driver or rasterizer artifact.

Anything *below* these bars is drift, not quantization — and the
usual cause is a buffer that should be f32 (an accumulator, or a separable
filter's intermediate) being stored as half. `retouch-probe` is macOS-only —
off Apple, gate on the CLI synth→fuse→compare path plus the Qt shell selftest
matrix.

---

## Bugs

- The error message for a failed fuse is terrible: "registration failed for frame pair at index 2". It's not capitalized and certainly not written for an end user's consumption.

## Cross-platform port (Windows/Linux)

The engine, CLI, and Qt/QML shell are **landed at feature parity** on macOS,
Windows, and Linux. Durable strategy and what shipped: `Docs/cross-platform-plan.md`
(+ git history). Remaining:

- **Rocking-animation MP4 on non-Apple.** GIF exports on all three OSes now
  (giflib, via `hf_gif_*`); H.264 is still Apple-only and the non-Apple path
  refuses a non-`.gif` filename rather than failing obscurely. The blocker is
  the encoder's licence, not the plumbing: distro FFmpeg builds are configured
  `--enable-gpl` and libx264 is GPL-only, neither of which MIT source + paid
  app-store builds can absorb. Pick a permissive encoder through the
  `third-party-deps` gate first — OpenH264 (BSD), FFmpeg's own LGPL-safe mpeg4,
  or the OS encoders (Media Foundation on Windows, VA-API on Linux).
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
    radius, blend radius, and despill sweeps all move it ≤1 point. The fix is
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
checklist. Residuals before shipping paid builds (each independently landable):

1. **The macOS half of the notices bundling.** The Windows package carries
   `NOTICE.md`, `LICENSE.txt`, `licenses/` and a generated `COMPLIANCE.md`, and
   both shells gained Help > Third-Party Notices reading a bundled copy
   (`Shell::noticesText` / `App/Sources/NoticesWindow.swift`); the Qt shell's
   selftest asserts the text is really there. `App/project.yml` already lists
   the two resource paths, but **nothing on the Mac side has been built or run**
   — that needs a Mac session: `cd App && xcodegen generate`, build, and check
   the menu item opens a populated window. Also still open there: the macOS
   About panel's credits blurb is a bare Swift `String` (not localized, unlike
   every other user-facing string) and still says the notices live "in the
   source distribution", which stops being true once the bundle carries them.

2. **Microsoft Store / MSIX submission.** `Scripts/package-windows.ps1` builds
   the payload and stages an MSIX-ready layout — `AppxManifest.xml` from
   `Packaging/windows/AppxManifest.xml.in`, generated logo assets, and a `-Msix`
   switch that runs `makeappx` — but it writes **placeholder identity**, because
   the real values come from a Store reservation. Remaining: reserve the package
   name, supply `-Identity` / `-Publisher` (the `CN=…` matching the signing
   cert) / `-PublisherDisplayName`, sign, and submit; then publish the same
   build off-Store. The LGPL-3.0 checklist the package was built to is settled
   and enforced in the script — Qt ships as replaceable DLLs (asserted), the
   GPLv3-only `qsb`/`lupdate`/`lrelease` tools are asserted absent, and the
   GPL-3.0 + LGPL-3.0 texts plus the written 3-year source offer ride in
   `COMPLIANCE.md`. The off-Store build stays load-bearing: it is the mitigation
   for the one genuinely-unsettled point (MSIX vs LGPL §4(d)(1)
   DLL-replaceability, since the `WindowsApps` copy is locked) and it also
   covers the small static `libQt6QmlBuiltins.a` fragment (Qt 6.7+).

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
- **f16 storage on the wgpu backend (Windows/Linux GPU).** `ImageBuffer` and
  the Metal kernels are f16 now; the WGSL kernels are still f32, and
  `WgpuDMap`/`WgpuPyramid` widen through an f32 staging array at every
  host↔device RGBA transfer to stay correct. So the wgpu path pays a
  conversion it doesn't need and gets none of the bandwidth or footprint win.
  Port it via **`pack2x16float` / `unpack2x16float`** — core WGSL, so an RGBA
  half4 is 2 `u32` words and no `shader-f16` feature is required. That matters:
  `shader-f16` is not universal, and the only validated surfaces here are WARP
  and llvmpipe. Mirror the Metal split exactly — accumulators (`tent_accumulate`'s
  accum, the pyramid base sum) and the separable blur's H→V intermediate stay
  f32; see `MetalEngine`'s kernel header for why each one does. This port is
  also what should retire the warped-dmap exception in the header: it exists
  precisely because these kernels are f32 under f16 storage, and Metal — which
  has no such asymmetry — clears 90 on the same frames. Done = the staging
  arrays in `WgpuDMap` are gone, `WgpuParity` passes, and warped dmap parity is
  back at **90**, not 71. Before starting, read the refuted experiment in
  `Docs/performance.md`: quantizing *only* the warp output to f16 on-device, to
  match the CPU's storage, measurably worsened warped dmap parity — so this has
  to move the whole kernel chain to half, not narrow at one seam.
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
- **wgpu static-link rollout.** Both fusion paths run on the wgpu/WGSL backend
  (opt-in `HYPERFOCAL_WGPU=1`; validated on WARP + llvmpipe, real-hardware
  speedups still unmeasured — the dev VM has no hardware DX12).
  `HYPERFOCAL_WGPU_STATIC=1` is proven on macOS and Windows. Remaining: verify
  the static link on **Linux** (`libwgpu_native.a`, same shape as the macOS
  branch in `Package.swift`).
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
- **PMax despill inputs on Metal + wgpu.** `--despill --method pmax` currently
  forces the CPU engine: the pass needs the per-frame grid luminance plane and
  the per-cell max of the grit-blurred level-0 focus, and only
  `PyramidFusion`'s CPU streaming loop retains them (`prepareDespill` →
  `Despill.DespillInputs`). Porting means computing both reductions on-device in
  `GPUPyramid`/`WgpuPyramid` and reading back at grid resolution, gated on
  CPU↔GPU parity of the despill inputs (DMap's equivalent measured ~74 dB).
  The stakes rose since this was written: DMap's render cleanup (despill +
  self-gated black point, `StackPipeline.applyRenderCleanup`) is now always-on
  in the pipeline and the CLI, but PMax only gets the black-point half — its
  despill stays opt-in-and-CPU until these inputs exist on the GPU, so PMax
  results keep their rim glow at default settings. The GPU pmax path measures
  ~1.6-1.9x faster than the CPU one, so forcing CPU is a real cost. The
  debloom near-black gate's port (git history) is the worked example — shared
  mask/statistics code called by every backend, with only the buffer plumbing
  per engine. Done = the pipeline turns despill on for PMax on every engine
  and the rim profiles (see `Docs/research/2026-07-25-rim-quality-measurement.md`)
  match the DMap result on the same stack.
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
