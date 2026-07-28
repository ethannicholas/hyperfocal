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
refuted one-seam fix: `WgpuParity.runDMap`.

Anything *below* these bars is drift, not quantization — and the
usual cause is a buffer that should be f32 (an accumulator, or a separable
filter's intermediate) being stored as half. `retouch-probe` is macOS-only —
off Apple, gate on the CLI synth→fuse→compare path plus the Qt shell selftest
matrix.

---

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
  - **Full side-by-side UI divergence audit.** The dual-UI invariant is
    enforced for *existence* (a control is in both shells) and for strings (the
    translation gate), but nothing checks that the two shells *present* the same
    control the same way — and they have drifted. Two independent divergences
    were found in a single screenshot comparison of the Fusion card: the
    algorithm radios were laid out label-above-radios instead of native's
    `LabeledContent` label-beside-column, and seven sliders formatted their
    values differently (Qt's `SidebarSlider` had no `displayScale` or
    signed-format support, so native's `5%` read `0.05` and `+25` read `25`).
    Both are now fixed; the point of this item is that they were found by
    eye, one card at a time, which means the rest of the sidebar has not been
    checked. Walk **every** section of both shells side by side — Stack,
    Fusion, Tone, Crop, Retouch, Export, Settings, menus, dialogs — comparing
    layout (label placement, grouping, spacing, alignment), value formatting
    (decimals, units, signs, percents), control kinds, enable/disable
    conditions, and default states. Record each divergence and either fix it or
    add it to the "known non-native behaviors" list above with a reason.
    "Done" is a written pass over every section with no unrecorded difference.
    Method that worked: `hyperfocal-cli synth` a stack into a frames-only
    directory (keep `ground_truth.tif` out — it ingests as a bad 16th frame),
    then `hyperfocal-qt --selftest <frames> <out.tif> <shot.png>` with
    `HFQT_AUTOCONFIRM=1` for the Qt-side window grab, against a macOS
    screenshot of the same panel. Worth considering whether any part of this
    can become a gate rather than a one-off audit — the formatting drift in
    particular is comparable data on both sides.

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
    and engine parity). Implementation starts from that note's criteria.
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
  `Docs/performance.md`.
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
