# Windows/Linux port — evaluation (2026-07-17)

Investigation of what a Windows/Linux port of Hyperfocal entails, the
alternative strategies considered, and their tradeoffs. The **decided
direction and phased plan** live in `Docs/cross-platform-plan.md`; this
document is the evidence and the record of why.

Method: three parallel code investigations (engine/GPU dependencies, UI
layer, media I/O) over the full source tree at commit state of
2026-07-17. LOC figures from `wc -l`.

---

## 1. Engine (HyperfocalKit, ~7,000 LOC + 641 CLI)

### Already portable: the entire algorithmic core (~44%)

`DMapFusion` (871), `DepthRegularize` (477), `PyramidFusion` (252),
`StackPipeline` (264), `Filters` (220), `Warp` (162), `ToneCurve` (127),
`ImageBuffer` (123), `FrameSharpness` (85), `XMPSidecar` (135),
`FramePrefetcher` (98), `Metrics` (63), `FusionProgress` (50),
`StackSource` (44) — **~3,100 LOC** — compile with only Foundation,
Dispatch, and stdlib SIMD, all available in Swift on Windows/Linux.

- **No Accelerate, no MPS, no os.log, no async/await** — all heavy math
  is hand-written per-pixel loops over `[Float]` with
  `withUnsafe(Mutable)BufferPointer` (portable stdlib API, 176 sites)
  parallelized via `DispatchQueue.concurrentPerform` (swift-corelibs
  provides libdispatch on both target platforms).
- `simd` module usage is almost entirely `simd_float3x3` +
  `matrix_identity_float3x3` + `.inverse` (Aligner 14 refs,
  StackPipeline 9, Warp 7, others ≤3). `SIMD3/SIMD4` are Swift stdlib.
  A ~50-line matrix shim covers non-Apple platforms.
- The `-O`-even-in-Debug engine flag (Package.swift) must carry to other
  platforms — the loops are 30–50× slower unoptimized.

### The Metal path is droppable for a first port

- All GPU code is **26 buffer-based compute kernels** in a single
  embedded MSL string (`MetalEngine.kernelSource`, ~590 lines), compiled
  at runtime; there are no `.metal` files. Only three files import Metal
  (`MetalEngine`, `GPUDMap`, `GPUPyramid`, ~1,776 LOC Swift total),
  always behind `MetalEngine.shared != nil` with silent CPU fallback on
  error.
- **Every kernel has a pure-Swift CPU equivalent, and the CPU path is
  the reference implementation** (parity ≥ 90 dB is a regression gate).
  The GPU depth path even calls shared CPU code
  (`DMapFusion.peakConcentrationPlane`, `DepthRegularize.
  gridCoefficients`) so parity is by construction. A CPU-only port
  fuses correctly with zero GPU work.
- Kernels operate on raw Float32 buffers, not textures — mechanically
  translatable to WGSL (wgpu/Dawn: one backend covering D3D12 + Vulkan
  + Metal) if/when a GPU backend is warranted. The existing parity gate
  validates any new backend automatically.

### Apple-framework edges to replace (~1,800 LOC, concentrated in 5 files)

| Dependency | Where | Replacement | Risk |
|---|---|---|---|
| `CIRAWFilter` RAW decode → Display-P3 Float32 | `ImageFile.loadRAW` (full-quality demosaic, as-shot WB, orientation applied upstream) | LibRaw (`use_camera_wb`, `flip`, `cam_mul` for as-shot neutral) + lcms2 for P3 float output | **High** — not bit-identical to Apple demosaic; per-camera support lags on newest bodies |
| Vision homography registration | `Aligner.register(moving:fixed:)` — **one ~10-line function** (`VNHomographicImageRegistrationRequest` on gradient-magnitude gray images → `matrix_float3x3`, plus a bottom-left→top-left convention flip). The surrounding ~500 LOC of chain/outlier/spur logic is pure Swift. | OpenCV `findHomography`/ECC behind the same signature | Low-Med — narrowest interface in the codebase; alignment quality needs validation |
| JPEG/TIFF/PNG read/write, 16-bit, ICC | `ImageFile` (ImageIO/CG tagged-colorspace draws) | libjpeg-turbo / libtiff / libpng + lcms2 | Low |
| EXIF read (capture-time stack splitting, camera/lens/GPS carry-over) | `StackSplitter`, `DNGWriter.sourceMetadata` (ImageIO property dicts) | exiv2 (or libexif) | Low |
| MP4 (H.264) + GIF rocking export | `RockingAnimation` — AVFoundation `AVAssetWriter` + ImageIO GIF; only ~140 of 324 LOC — the warp/disparity math is pure Swift | FFmpeg (or Media Foundation) + giflib | Med |
| Scratch spill | `FrameSpill` (110 LOC POSIX: `open`/`unlink`/`pwrite`/`pread`, Darwin-only `F_NOCACHE`, unlink-open-fd idiom, `volumeAvailableCapacityForImportantUsage`) | As-is on Linux (+`posix_fadvise`, `statvfs`); Windows needs `FILE_FLAG_DELETE_ON_CLOSE`/`NO_BUFFERING`/`GetDiskFreeSpaceEx` variant | Low (Linux) / Med (Win) |

### Already portable, verified

- **DNG output**: the vendored Adobe DNG SDK is integrated via a C shim
  (`CDNGSDK`, `dng_shim.cpp`), XMP/libjpeg/JXL compiled out, only zlib
  linked. The SDK has first-class `qWinOS`/`qLinux` support
  (`dng_flags.h`), Win32 pthread shims, and portable file streams —
  porting is a compile-flag flip. There is also a zero-dependency
  pure-Swift uncompressed-DNG fallback (`DNGWriter.writeUncompressed`)
  and the XMP-embed path (`XMPSidecar`) is hand-rolled byte
  manipulation, portable as-is.
- Synth fixtures are **TIFF**, so the synth→fuse→PSNR regression gates
  are decode-backend-independent and portable to all platforms
  unchanged. This is the cross-platform correctness harness, for free.

## 2. App layer (7,361 LOC)

- The performance-critical surfaces are deliberately **not SwiftUI**
  (see CLAUDE.md invariant): image panes and retouch canvas are custom
  AppKit views — `CIColorCubeWithColorSpace` CALayer filters
  (`layerUsesCoreImageFilters`), manual CG drawing with zero-copy
  CGImage buffers, dirty-rect invalidation, raw `NSEvent`
  scroll/magnify/keyCode handling. 5 `NSViewRepresentable` bridges + 8
  `NSView` subclasses; the crop overlay (~470 LOC) and retouch
  canvas/session (848 LOC) are the two dominant custom widgets. **Any
  port re-implements these as custom GPU-composited widgets regardless
  of toolkit** — the chrome (sidebar, sliders, tree, menus) is the easy
  part.
- **The model layer is less shareable than the Probe target implies.**
  Probe compiles `AppModel`/`Stack`/`ProjectStore`/`RetouchSession`
  *headless*, not AppKit-free: `AppModel` (3,086 LOC) publishes
  `NSImage` as its image currency, calls
  `NSOpenPanel`/`NSSavePanel`/`NSAlert` inline (~24 sites), and rides
  Combine `ObservableObject`. `ProjectStore` is the only genuinely
  toolkit-free file. Sharing the model with a second frontend requires:
  neutral image type (the CGImage/ImageBuffer layer already exists
  underneath), a dialog/alert protocol, and an observation
  abstraction. Mechanical, concentrated in `AppModel`, and identical
  regardless of which UI strategy is chosen.
- Platform glue needing per-OS equivalents: sandbox + security-scoped
  bookmarks (persisted in project files — plain paths elsewhere),
  `.itemReplacementDirectory` atomic writes, UserDefaults suite,
  `DistributedNotificationCenter` test command channel, NSApplication/
  NSWindow lifecycle, ~14 file-dialog sites with accessory views.

## 3. Alternatives considered

**Foundation work common to every plan** (and therefore no-regrets):
extract a toolkit-neutral `AppCore` (kills the Probe copy-drift hack as
a side effect); port the engine edges behind per-platform backends;
ship the CLI cross-platform first as the regression vehicle; GPU
backend deferred until measurement demands it.

### Plan A — three native UIs (SwiftUI + WinUI 3 + GTK/Qt)
- ✅ Zero Mac look-and-feel risk; best native feel on Windows too.
- ❌ Every UI-heavy feature costs 3×; the two hardest widgets (retouch,
  crop) hand-built per toolkit; three UI automation harnesses; slowest
  path (~3–5 months per additional platform UI); Swift-on-Windows
  toolchain becomes release-critical.

### Plan B — Mac native + one Qt UI for Windows/Linux  ← **chosen**
- ✅ Mac app untouched; one new UI covers both new platforms; Qt's
  custom-widget path suits the pane rendering (GPU LUT shader ≈ the CI
  color cube); market-normal (Helicon Focus is Qt, Zerene is Java —
  non-native is expected in this niche).
- ❌ Language seam: Swift AppCore ↔ C++/QML UI needs a C-ABI bridge
  (design work, prototype first). Win/Linux app is non-native in feel.
  Qt LGPL dynamic-linking constraint on a paid app.
- **Amendment (Ethan, 2026-07-17): the Qt shell must also build and run
  on macOS** as a development/validation target (not shipped to Mac
  users). UI feature work then happens once on a Mac: implement in the
  native app, mirror in the Qt shell, validate both locally; Windows/
  Linux are final-validation only. This converts "fan out to three
  platforms per feature" into "develop on one, validate on two."

### Plan C — one cross-platform UI everywhere
- ✅ Single UI codebase; versions cannot drift.
- ❌ Rejected: spends the non-negotiable constraint (Mac look-and-feel,
  native menus/dialogs/sheets, MAS/sandbox integration, the validated
  XCUITest journey suite, a shipping polished UI) to optimize the
  negotiable one (sync cost). Months to re-earn today's Mac quality.

## 4. Cross-cutting decisions

1. **RAW decode divergence — decided:** keep `CIRAWFilter` on macOS
   (quality + newest-camera support), LibRaw on Windows/Linux. Accepted
   consequence: the same stack renders measurably (not grossly)
   differently across platforms; `.hyperfocal` projects remain
   portable but re-render per-platform. Revisit only if users actually
   roundtrip projects across OSes.
2. **Registration — decided pending validation:** implement OpenCV
   homography behind `Aligner.register`'s existing signature and
   validate against Vision with the existing residual-scoring harness
   plus real stacks. **If it matches Vision's quality, adopt OpenCV on
   all platforms including macOS** — eliminating divergence in the most
   quality-critical stage outweighs Vision's convenience.
3. **GPU strategy:** CPU-only first release on Windows/Linux (fusion at
   45 MP is RAW-decode-bound; see ROADMAP measurement note). If GPU is
   later warranted: one wgpu/WGSL compute backend, validated by the
   existing CPU↔GPU parity gate.
