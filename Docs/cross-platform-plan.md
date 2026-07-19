# Cross-platform plan: Windows & Linux

The decided strategy for porting Hyperfocal beyond macOS, and the phased
plan to get there. Evidence and rejected alternatives:
`Docs/research/2026-07-17-windows-linux-port-evaluation.md` (2026-07-17).
Actionable near-term items are mirrored in ROADMAP.md; this document is
the durable statement of direction — update it when direction changes,
not per completed task.

## Strategy (decided 2026-07-17)

- **macOS keeps the native SwiftUI/AppKit app unchanged.** Its
  look-and-feel is the non-negotiable constraint; nothing in this plan
  may degrade it.
- **Windows and Linux share one Qt frontend** (C++/QML) over the shared
  Swift core. Non-native chrome is market-normal in this niche (Helicon
  Focus is Qt, Zerene is Java).
- **The Qt shell also builds and runs on macOS**, as a development and
  validation target only — never shipped to Mac users. This is the key
  cost-reduction move: UI feature work happens once, on a Mac
  (implement native, mirror in Qt, compare side-by-side against the
  same AppCore); Windows and Linux runs are final validation, not
  development.
- **Shared across all platforms:** `HyperfocalKit` (engine),
  `AppCore` (model/orchestration layer, extracted from the app),
  `hyperfocal-cli`, the synth/probe/PSNR regression harness, and the
  `.hyperfocal` project format.
- **Per-platform:** the SwiftUI/AppKit shell (macOS) and the Qt shell
  (Windows/Linux primary, macOS dev target); OS glue (dialogs, settings
  storage, spill file, video encode backend, installers).

### Decisions of record

1. **RAW decode:** `CIRAWFilter` stays on macOS; LibRaw (+ lcms2 for
   Display-P3 float) on Windows/Linux. Accepted: per-platform render
   divergence; projects stay portable but re-render per-platform.
   Known hole (decided 2026-07-19): lossy/High-Efficiency NEFs are
   TicoRAW, undecodable by any open-source library — users convert to
   DNG externally; integration punted, see
   `Docs/research/2026-07-19-lossy-nef-linux.md`.
2. **Registration:** **settled (2026-07-18) — Vision stays on macOS,
   OpenCV (SIFT + RANSAC) is the Linux backend.** The seam moved off
   `CGImage` to a portable `GrayImage`; the OpenCV backend was built and
   A/B'd against Vision on macOS with decode/color/downscale held
   identical, so the comparison isolates registration. Result: OpenCV was
   parity-or-better on the synth plane (39.1 vs 38.7 dB) and on the real
   fluorite stack (matching post-warp residuals, zero failures), but lost
   ~5.6 dB on the synth *object* scene — an isolated high-contrast subject
   on a black field, where SIFT features clump on the subject and skew the
   global homography. By the pre-registered criterion ("Vision stays only
   if OpenCV measurably loses") that object-scene regression keeps Vision
   on macOS. On Linux OpenCV is used regardless — there is no Vision to
   fall back to. Accepted: per-platform registration divergence, alongside
   the RAW-decode divergence. The A/B harness stays in the tree
   (`COpenCVRegister`, macOS-only; build the CLI with
   `HYPERFOCAL_OPENCV_AB=1 swift build`, then run with
   `HYPERFOCAL_REGISTER=opencv`) as the revalidation vehicle if the
   object-scene gap is ever closed. The build-time flag is a deliberate
   opt-in: auto-detecting an installed Homebrew OpenCV linked its
   ad-hoc-signed dylibs into the app, whose library validation kills the
   process at launch (different Team IDs) — the app must always build
   Vision-only. Evidence:
   `Docs/research/2026-07-17-windows-linux-port-evaluation.md` and the
   Phase 1.5 commit.
3. **GPU:** Windows/Linux ship CPU-only first (the CPU path is the
   reference implementation; 45 MP fusion is decode-bound). If profiling
   later justifies it: one wgpu/WGSL compute backend translated from the
   26 buffer-based MSL kernels, validated by the existing ≥90 dB parity
   gate. No per-OS Vulkan/D3D ports.
4. **Engine language stays Swift on all platforms** (swift.org
   toolchains for Windows/Linux). The ~3,100-LOC validated algorithmic
   core ports as-is; rewriting it would forfeit the regression history.
5. **Qt licensing:** LGPL, dynamically linked.

## Phases

Every phase keeps the existing gates green on macOS: `swift build`,
`retouch-probe … ALL PASS`, synth PSNR baselines (ROADMAP header),
`Scripts/ui-test.sh` for UI-layer changes.

### Phase 0 — AppCore seam (macOS-only, zero behavior change)

Extract the shared model layer so both the native app and any future
shell sit on one module.

0a. **Single source of truth for the model files.** Move `AppModel`,
    `Stack`, `ProjectStore`, `RetouchSession` out of `App/Sources` into
    a shared `AppCore/` location consumed by both the app target and the
    probe; delete the `Probe/` verbatim copies and the cp-to-sync rule.
0b. **Dialog/alert seam.** Replace inline `NSOpenPanel`/`NSSavePanel`/
    `NSAlert` calls (~24 sites in `AppModel`) with a `DialogService`
    protocol; the Mac implementation wraps the same panels (pixel-
    identical behavior), the Qt shell later provides its own.
0c. **Neutral image currency.** Replace `NSImage` in model-published
    state (`AppModel`, `Stack`, `RetouchSession` caches) with the
    CGImage/ImageBuffer layer that already sits beneath it; views wrap
    at the edge.
0d. **Observation seam.** Isolate `ObservableObject`/`@Published`
    (Combine) behind a change-notification surface the C-ABI bridge can
    subscribe to later.

Done = probe imports AppCore (no copies), app builds & UI tests pass,
no user-visible change.

### Phase 1 — portable engine + CLI (first shippable artifact)

- Backend seams in the engine edges, selected at build time:
  decode/encode (`ImageFile`: ImageIO/CIRAW on Mac; LibRaw +
  libjpeg-turbo/libtiff/libpng + lcms2 elsewhere), EXIF
  (`StackSplitter`/`DNGWriter`: ImageIO on Mac, exiv2 elsewhere),
  `simd_float3x3` shim, `FrameSpill` Win32 variant, DNG SDK
  `qWinOS`/`qLinux` flags (already supported by the vendored SDK).
- CI: Linux (container) and Windows builds running the synth →
  fuse → PSNR gates (synth fixtures are TIFF, so the gates are
  decode-backend-independent and port unchanged).
- Deliverable: **hyperfocal-cli on Windows/Linux** — headless batch
  fusion as a real product and the permanent regression vehicle for the
  non-Mac stack.

### Phase 1.5 — registration decision gate ✔ decided 2026-07-18

Done. OpenCV backend built behind `Aligner.register` and A/B'd against
Vision on macOS (registration isolated: shared decode/color/downscale).
**Outcome: Vision on Mac, OpenCV on Linux** — see decision 2 above for the
evidence (plane/fluorite parity; ~5.6 dB object-scene regression is the
deciding loss). Divergence documented next to the RAW-decode divergence.

### Phase 2 — C-ABI bridge + Qt shell walking skeleton (on macOS)

- **Prototype the bridge first** — it is the load-bearing design risk:
  a C-ABI wrapper over AppCore (command-style calls in, change
  notifications + zero-copy pixel buffers out; `@_cdecl` exports).
  Prove: open stack → fuse → pan/zoom pane → tone slider → export,
  driven from a minimal Qt window on macOS.
- Then build out the Qt shell feature-by-feature against the native app
  side-by-side on the same machine: chrome in QML; the four custom
  widgets (toned pane w/ LUT shader, pan/zoom, retouch canvas, crop
  overlay) as custom QQuickItems with the same dirty-rect zero-copy
  discipline the AppKit views use.
- Automation harness: port the journey-test concept (command channel +
  container-file inspection) to the Qt shell so both frontends run the
  same functional journeys.

### Phase 3 — Windows/Linux productization

Platform glue (file dialogs, settings storage, atomic writes without
the sandbox dance, plain-path project bookmarks), FFmpeg/giflib rocking
export, installers/packaging (MSIX or Inno; AppImage/Flatpak), final
validation passes on real Windows/Linux hardware.

### Phase 4 (deferred, measurement-gated) — GPU backend

wgpu/WGSL compute port of the 26 kernels, only if Windows/Linux CPU
performance on real stacks demands it. Parity gate validates.

## Development workflow once Phase 2 lands

New feature → engine/AppCore work (shared, written once) → native
SwiftUI UI + Qt UI, both implemented and compared **on the Mac** →
probe + synth gates + both journey suites locally → Windows/Linux CI
plus a short manual final-validation pass before release. Releases of
the three platforms version together from one repo.
