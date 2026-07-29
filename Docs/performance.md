# Engine performance notes

Living reference for fusion-performance work: where the time goes, what has been
tried and rejected, and how to measure. ROADMAP.md keeps the forward *goal*
(hit the throughput bar); the data and dead-ends live here so the roadmap stays
skimmable.

## Measurement environment

**Every absolute number in this file must be tagged with the machine it was
measured on and the date it was gathered.** Numbers go stale on both axes —
the code changes underneath them, and the machines get replaced or upgraded —
and an untagged number is unusable for exactly the reason the pre-2026-07-29
Apple entries had to be retaken: nobody could say which of two far-apart
machines produced them. Use the short names below; the roster carries the
specs so individual entries don't have to.

- **Mac Studio** — Mac Studio (2022, Mac13,1): Apple M1 Max, 10-core CPU
  (8 P + 2 E), 24-core GPU, 64 GB unified memory. macOS 26.5 as of
  2026-07-29.
- **MacBook Pro** — M1-family Apple laptop. *(Exact model/specs to be filled
  in; older notes imply roughly 4 performance cores and ~68 GB/s of memory
  bandwidth, i.e. a plain M1.)*
- **Windows Desktop** — 8-core / 16-thread Zen 4, 32 GB, discrete NVIDIA GPU,
  Windows 11. *(Exact CPU and GPU models to be filled in.)*
- **ARM64 dev VM** — Windows-on-ARM VM, 2 cores / 8 GB, no real GPU (WARP
  only). Numbers from it are **relative, not absolute** — perf targets are
  hardware-relative (the bar is commercial-stacker speed on the *same*
  machine). The VM also drifts slower over a long session, so only interleaved
  A/Bs settle close calls. Retired for new measurements once the Windows
  Desktop arrived (2026-07-28).

Historical caveat: Apple numbers gathered **before 2026-07-29** never recorded
which machine (MacBook Pro or Mac Studio) produced them, so they bound the M1
*family*, not a machine. Where such a number survives below it is marked
"machine unrecorded"; current Apple absolutes live in the Mac Studio reference
section.

Sampling profilers can't run in the VM (the hypervisor doesn't virtualize the
profiling interrupt — WPA/VS/Superluminal all need it); use instrumented
decomposition (phase buckets + scratch benches). On real Windows hardware,
`wpr` + WPA symbolize with `swift build -Xswiftc -debug-info-format=codeview
-Xlinker /DEBUG`.

**The VM had no real GPU**, and that invalidated more than it looks like. Its
only wgpu adapter was the D3D12 WARP software rasterizer, which
`usableForAutoSelection` deliberately skips — so on that machine the wgpu
backend was reachable only by forcing `--engine gpu`, and every default-path
measurement was the CPU engine. Two consequences worth keeping in mind when
reading older entries: no pre-2026-07-28 number here describes wgpu on real
hardware, and the backend's **1-D dispatch limit went unnoticed for its whole
life** — WebGPU caps a dispatch at 65535 workgroups per dimension, so the flat
1-D grid topped out near 16.8 M elements (~4 MP of RGBA) and aborted the process
above it. Nothing caught it because the parity fixtures are 360×240 and the only
adapter that ran real stacks was skipped by default. Fixed 2026-07-28 by tiling
the grid into Y (`WgpuEngine.Batch.dispatch` + `flatten1D` in the WGSL).

## Throughput bar

**< 2 min end-to-end** on the reference stacks (measured against commercial
stackers on the VM). pmax is close; dmap has further to go.

### 11 MP reference — 82 × 11 MP JPEGs: dmap ~175 s, pmax ~132 s (ARM64 dev VM, pre-2026-07-28)

- **Registration 46–48 s** = SIFT detect ~32 s (DoG pyramid dominates — the
  2000-keypoint cap is *not* the wall) + match ~14 s + decode/gradient glue
  ~2.5 s (down from ~15 s before the ¼-scale JPEG gray decode). **A genuinely
  cheaper feature detector is the biggest remaining prize.**
- **Warp** 59 s (pmax) / 71 s (dmap; the ~12 s delta is async spill I/O taxing
  compute). The loop is at its practical floor — SIMD8 pair taps, cost split
  ~41 ns/px (weights ~16, taps ~7, homography/divides/clamp/store ~19; scalar
  LUT weights beat vectorized — SIMD8<Int32> conversion inits are unspecialized
  generics). Dead ends recorded in `WarpBench.swift` (`debug-bench warp`); don't
  expect more here without changing outputs.
- **dmap spill round-trip** — io ~42 s (fp16, overlapped under compute) +
  render-src ~18 s reading it back.
- **energy ~16 s**; select/regularize/render ~7 s.

### 45 MP reference — 10 × 45 MP DNG (`~/Desktop/Fluorite`): dmap ~295 s (ARM64 dev VM, pre-2026-07-28)

Achieved after (a) registration gray decoding RAW at LibRaw half-size (124 → 30 s
registration) and (b) a **proportional spill margin** `max(2 GB, spill/2)` — a
flat 2 GB margin let a 7.3 GB fp32 spill drive the volume to 97 % full, where
write latency collapses (2124 s vs 469 s forced-fp16; fp16 matches real content
at 95.9 dB, far better than the 79.5 dB synth characterization).

Remaining walls, in order: warp ~86 s (memory-pressure-inflated, ~2× the bench
rate; 4.9 GB peak on 8 GB), spill io ~48 s + render-src ~33 s (fp16), energy
~28 s, decode-blocked ~44 s (LibRaw full demosaic ×1 for fusion — prefetch can't
fully hide ~11 s/frame on 2 cores), registration 30 s. **At this size,
frames-at-once *memory* (not time) is the likelier next lever.**

## Real-hardware reference (Windows Desktop, 2026-07-28)

First measurements on the Windows Desktop, and the first anywhere of the wgpu
backend on a real GPU (adapter reports through wgpu's Vulkan backend). **Synth
stacks, so these are not comparable to the DNG reference stacks above**: synth
frames are TIFFs, and TIFF reads are far cheaper than a LibRaw demosaic. Read
this section for the CPU↔GPU *split* and the phase shape, not as a speedup over
the VM's end-to-end numbers.

Wall clock, whole `fuse` process including registration and export. Best of 3
(12 MP) / best of 2 (45 MP). The bracketed figures are the same runs *before*
the x86-64 ISA baseline below — the single largest engine speedup measured on
this platform, and the reason to read the older entries in this file with the
target architecture in mind:

| stack | dmap cpu | dmap gpu | pmax cpu | pmax gpu |
|---|---|---|---|---|
| 12 MP × 17 (4240×2832) | 15.6 s *(21.8)* | 14.8 s *(19.1)* | 15.1 s *(23.9)* | **13.1 s** *(14.3)* |
| 45 MP × 10 (8192×5464) | 37.8 s *(52.2)* | 35.7 s *(44.6)* | 35.8 s *(58.0)* | **30.0 s** *(33.7)* |

Both sizes clear the < 2 min throughput bar with room to spare. CPU↔GPU
agreement on the *fused output* — a stronger end-to-end check than the
kernel-level parity suite, which only sees small fixtures — is 80.1 dB (dmap)
and 67.6 dB (pmax) at 12 MP, 82.2 / 68.2 at 45 MP, **unchanged by the ISA
switch**: both sit in the band f16 pixel storage imposes, consistent with the
ROADMAP's floors.

Phase split at 12 MP (`-v`), pre-ISA figures bracketed:

| phase | dmap cpu | pmax cpu | pmax gpu |
|---|---|---|---|
| registration (CPU, before fuse) | 6.67 s *(6.68)* | 6.73 s *(6.73)* | 6.69 s *(6.71)* |
| decode | 1.76 s *(1.84)* | 1.83 s *(1.82)* | 2.38 s wait *(2.01)* |
| warp | 3.13 s *(9.00)* | 3.22 s *(8.86)* | — (on device) |
| energy / build + select + collapse | 2.29 s *(2.24)* | 2.19 s *(5.31)* | — |
| upload | — | — | 1.50 s *(2.75)* |
| **GPU compute** | — | — | **0.59 s** *(0.31)* |
| **fuse subtotal** | **7.88 s** *(13.82)* | **7.51 s** *(16.29)* | **5.45 s** *(6.30)* |

**CPU fusion moved from far behind Apple silicon to the same order.** At the
time this was written the comparison was against a machine-unrecorded M1-family
entry (7.41 s dmap/cpu, 6.52 s pmax/cpu on the same 12 MP × 17 shape); the
tagged retake (Mac Studio reference below, 2026-07-29) puts the Mac Studio's
fuse subtotals at 3.79 s (dmap/cpu) and 3.50 s (pmax/cpu) against this
desktop's 7.88 and 7.51 — so the desktop is at parity with what the old entry
*probably* was (the MacBook Pro) and ~2.1× behind the M1 Max. Before the ISA
fix it was 13.82 and 16.29.

**On the GPU path Apple is further ahead**, and the cause is architectural
rather than a missed optimization: the Mac Studio's pmax/gpu fuse subtotal is
0.95 s against this desktop's 5.45 s, and the desktop's 1.50 s upload — which
a unified-memory machine never pays (the Mac Studio's upload span is 0.07 s) —
plus its 2.38 s decode-wait are most of that gap. dmap/gpu sits further back
because its warp and spill round-trip stay on the CPU, so it barely uses the
device at all.

**The CPU path is compute-bound, not bandwidth-bound** — worth knowing before
anyone attributes the remaining gap to memory. The warp bench under processor
affinity (`ProcessorAffinity` over alternating logical CPUs, so the counts are
physical cores) scales 86.0 → 42.7 → 21.6 → 11.0 ns/px across 1/2/4/8 cores, a
**7.82× speedup on 8 cores** (98 % efficiency), with SMT adding a further 26 %
to 8.7 ns/px. DRAM bandwidth would have flattened that curve by 4 cores. The
memory system *does* show up one level out, though: the same loop costs
15.6 ns/px inside a production fuse (3.13 s / 200 Mpx) versus 8.7 ns/px
isolated — 1.8× lost to decode and spill traffic competing with it, which is a
phase-overlap problem rather than a starved kernel.

**Registration is the dominant cost and did not move** — ~6.7 s, identical
across every configuration and unchanged by the ISA switch, because it is
OpenCV SIFT and OpenCV already dispatches SIMD at runtime. It is now **51 % of
the fastest configuration's wall clock** (pmax/gpu, 13.1 s total). The "cheaper
feature detector" item was already flagged as the biggest remaining prize; it is
now the only one of consequence on this platform.

**The GPU remains idle almost the whole time it is "working": 0.59 s of compute
behind 2.38 s of decode-wait and 1.50 s of upload.** Nothing in the fusion
kernels is worth optimizing at this size — the cost is feeding them. Upload
overlap (decode → upload pipelining, or persistent staging buffers) is the only
GPU-side lever that could pay, and a perfect one now saves ~1.5 s. Note the CPU
paths gained so much that the GPU's *margin* shrank: pmax/gpu was 1.68× faster
than pmax/cpu before, and is 1.15× now.

### The x86-64 ISA baseline (the big one)

Swift defaults to the generic `x86-64` target: SSE2, no AVX, and **no F16C**.
Pixel storage is `Float16` and every per-pixel loop crosses that boundary, which
on Apple silicon is one native `fcvtl`/`fcvtn` but compiled here to a
compiler-rt **software call**. Evidence, before the fix: `__truncsfhf2`
referenced by 18 of HyperfocalKit's object files, and **zero AVX instructions in
the entire engine** (`llvm-objdump -d`, counting `ymm`). After
`-target-cpu haswell`: 1474 AVX instructions, zero software-f16 references.

So the f16 storage decision — a win on Apple silicon and on the GPU, recorded
below — was silently a *tax* on x86. Isolated effect on the warp loop
(`debug-bench warp`, 11 MP): **34.9 → 8.7 ns/px, 4.0×**.

Two things this did NOT turn out to be, both measured before the ISA was
suspected, and worth not re-testing: it is not a threading problem (the warp
bench runs at **13.8× parallelism** on 16 threads — the cores were fully busy
running bad code), and it is not the per-file specialization trap the contract
in `PortableSIMD.swift` warns about (release builds already whole-module).

Gotchas for anyone touching this:

- Swift's `-target-cpu` does **not** accept the `x86-64-v3` alias that Clang's
  `-march` does — its list ends at `x86-64, geode`. `haswell` is the portable
  spelling of that feature level (AVX2 + FMA + F16C + BMI). Passing an
  unaccepted name fails with `clang importer creation failed`, which does not
  obviously mean "bad CPU name".
- `-Xllvm -mcpu=…` is silently **ignored** — it does not reach Swift's IRGen.
  The first attempt with it built cleanly and changed nothing; always verify a
  codegen flag landed by checking the objects, not by trusting the build.
- Results shift slightly (FMA contraction, different rounding order):
  baseline↔AVX2 fused output is 72.1 dB (dmap) / 67.8 dB (pmax). Quality against
  synth truth is unmoved (51.42 → 51.41, 50.45 → 50.46), the CI gate PSNRs are
  identical, and `debug-wgpu` parity is **bit-identical** (112.9 / 74.0 / 69.6).
  Re-run both gates after touching the baseline anyway.
- Applied to the Swift targets only. The C/C++ targets are thin wrappers over
  vcpkg libraries that already dispatch at runtime; raising their baseline is
  unmeasured and was left alone.

## Apple reference (Mac Studio, 2026-07-29)

The tagged retake of the Apple numbers, same synth shapes as the Windows
Desktop section above so the two tables read against each other. Wall clock is
the whole `fuse` process including registration and export; best of 3 (12 MP)
/ best of 2 (45 MP); run-to-run spread was under 2 % everywhere. "gpu" is the
Metal engine (the macOS default). One shape caveat: `synth` rounds an even
`--frames` count up to odd (`SynthStack.Options`), so `--frames 10` produces
**11** frames — the 45 MP row here fused 11, and the Windows section's "× 10"
label was likely the same 11-frame stack (verify next Windows session).

| stack | dmap cpu | dmap gpu | pmax cpu | pmax gpu |
|---|---|---|---|---|
| 12 MP × 17 (4240×2832 TIFF) | 5.99 s | 3.36 s | 5.56 s | **2.99 s** |
| 45 MP × 11 (8192×5464 TIFF) | 14.33 s | 7.95 s | 13.19 s | **7.04 s** |

Phase split at 12 MP (`-v`, best run):

| phase | dmap cpu | pmax cpu | pmax gpu |
|---|---|---|---|
| registration (CPU, before fuse) | 1.69 s | 1.69 s | 1.70 s |
| decode | 0.14 s | 0.14 s | 0.14 s wait |
| warp | 1.71 s | 1.67 s | — (on device) |
| energy / build + select + collapse | 0.96 s | 1.47 s | — |
| upload | — | — | 0.07 s |
| **GPU compute** | — | — | **0.43 s** |
| **fuse subtotal** | **3.79 s** | **3.50 s** | **0.95 s** |

(dmap cpu's remaining buckets — select, spill, regularize, render-src, render
— total 0.91 s. dmap gpu fuse subtotal: 1.15 s. Peak memory at 12 MP:
3.7–4.2 GB across all four configurations; at 45 MP: 12.9–13.3 GB.)

What the table says, read against the Windows Desktop:

- **Registration is ~4× cheaper here — 1.69 s against 6.7 s at 12 MP** — and
  it is a different implementation, Vision on macOS versus OpenCV SIFT
  elsewhere. It is still the dominant cost in the fastest configuration (57 %
  of pmax/gpu's 2.99 s wall), so the "cheaper feature detector" prize stands
  on both platforms, but the Windows side has the further-to-fall problem.
- **CPU fusion: the M1 Max leads the Zen 4 desktop ~2.1×** (fuse subtotals
  3.79/3.50 s against 7.88/7.51 s) — post-ISA-fix, so this is the honest
  architectural gap, dominated by memory bandwidth and the native-f16 warp.
- **GPU fusion: pmax/gpu fuse is 0.95 s against the desktop's 5.45 s.** The
  desktop pays 2.38 s of decode-wait and 1.50 s of upload the unified-memory
  machine doesn't (upload here spans 0.07 s); actual GPU compute is the same
  order (0.43 s vs 0.59 s).
- **CPU↔GPU fused-output agreement** (Metal vs CPU, same end-to-end check as
  the Windows section): dmap 95.6 dB (12 MP) / 101.1 dB (45 MP), pmax
  70.6 / 70.9 dB. pmax sits in the same f16-storage band as CPU↔wgpu on
  Windows (67.6 / 68.2); dmap agrees far more closely here than there
  (80.1 / 82.2) — consistent with the warped-variant wgpu parity notes below.

Note the pmax numbers are the first on any Apple machine since smoothed
selection + Burt expand shipped (2026-07-28), so they are not comparable to
pre-2026-07-28 pmax entries.

## Measured dead ends (don't re-try without new hardware or evidence)

- **Spill byte-reduction** (RGB + 8-bit-alpha slot layout, 13 B/px fp32 /
  7 B/px fp16, bit-identical fp32 round-trip proven): net-negative on the 2-core
  VM at 11 MP — write io is cache/flush-governed, not byte-proportional (~41–48 s
  regardless), and the strided pack cost +3 s convert plus inflated warp +4–9 s
  (2-core memory-bandwidth interference). Parked in the local `spill-rgb` stash;
  its −19 % footprint may pay on real hardware or at 45 MP (io term 3× larger) —
  measure there first. Note the *baseline* moved under it: the spill now stores
  the pipeline's own f16 pixels (8 B/px), so it is already half what those
  measurements assumed, and the fp32/fp16 tier split — with its
  `HYPERFOCAL_SPILL_FP16` A/B tap — is gone.
- **CPU-path cost of f16 storage**: the widen/narrow in the hot loops is real
  but small on Apple silicon (**M1 family, machine unrecorded**, ~2026-07-26)
  — 12 MP × 17 synth, best of 2: dmap/cpu 7.06 → 7.41 s (+5 %), pmax/cpu
  5.84 → 6.52 s (+12 %). The GPU paths, which are the default engine, got
  *faster* on the same stack (dmap 5.36 → 3.94 s, pmax 4.02 → 3.35 s) — half
  the bytes through every kernel. Peak footprint fell ~25 % across all four
  combinations (e.g. dmap/gpu 2.45 → 1.83 GB); it is not 50 % because decode
  buffers, the scalar f32 planes, and the Metal/OS baseline don't scale with
  pixel storage. The *relative* before/after deltas are the durable part —
  the f32 path is gone, so they can't be retaken. The absolute numbers are
  superseded by the Mac Studio reference (2026-07-29), whose figures land far
  below these — evidence the machine behind this entry was probably the
  MacBook Pro, though that is inference, not record.
- **Quantizing the wgpu warp output to f16 on-device**, to make the wgpu backend
  carry byte-identical halves to the CPU (`pack2x16float`/`unpack2x16float`, core
  WGSL — no `shader-f16` feature needed). Motivated by CPU↔wgpu dmap parity
  splitting by variant once pixel storage went f16: unwarped 106.3 dB, warped
  **78.2 dB** against a 90 dB bar (WARP, 9 × 360×240 synth plane scene). The fix
  made it **worse — 78.2 → 70.7 dB** (pyramid_warp 68.7 → 67.5), because the
  asymmetry it removes is many *small* disagreements and what it leaves is fewer
  *full-ulp* ones, which dmap's argmax amplifies into whole frame-index flips.
  Reverted. The residual gap is arithmetic, not drift: each engine resamples in
  f32 then stores through f16, so wherever their f32 results straddle a rounding
  boundary they land on adjacent halves, and 78 dB is inside the 75–80 dB ceiling
  f16 imposes near 1.0. Hence the warped variant carries its own 75 dB floor
  (`debug-wgpu --dmap-warp-floor`); a miss *below* that is drift and should be
  chased. Unwarped keeps 90 because both engines hold identical decoded halves
  and round their weighted averages the same way. Measured since (Mac Studio,
  2026-07-29): Metal's warped end-to-end dmap agreement with the CPU engine is
  95.6 dB at 12 MP / 101.1 dB at 45 MP (aligned synth fuses, so the warp path
  is exercised) — Metal does not show wgpu's warped-variant depression, which
  localizes that 78 dB residual to the wgpu backend's resample/store ordering
  rather than to warping per se.
- **Metal 4, and "what does Apple-silicon-only unlock?"** — asked when Intel
  support was dropped (2026-07-26), audited, and the answer is *nothing worth
  doing*. Two separate points, often conflated:
  - **Metal 4 is gated on the deployment target, not on Intel.** It needs
    macOS 26; ours is 14.0, so dropping Intel doesn't unlock it and raising the
    floor to 26 would cost the 14/15 installed base. What Metal 4 offers —
    explicit command encoding with argument tables, tensor/ML encoders, faster
    shader compilation, placement sparse heaps — targets engines bottlenecked on
    encoding overhead or ML inference. Ours is neither: measured GPU *compute*
    inside a 63-frame 42 MP fuse (M1 family, machine unrecorded, 2026-07-26)
    is 0.07–0.65 s (pmax) / ~1.2 s (dmap) out of a 33–52 s wall clock that is
    RAW decode and upload. There is no encoding overhead to reclaim.
  - **The engine was already written Apple-silicon-shaped**, so the strip was
    scripts, docs, and the site badge — no code. Audited and found clean: no
    `#if arch(...)` anywhere; every `MTLBuffer` is `.storageModeShared` with no
    `.storageModeManaged` / `didModifyRange` / `synchronize` blit path (which is
    what a discrete Intel GPU would have wanted); Homebrew is `/opt/homebrew`
    only. `MTLGPUFamily.apple7+` guarantees are now unconditional — SIMD-group
    reductions (`simd_sum`/`simd_shuffle`), quad ops, 32 KB threadgroup memory,
    imageblocks — but every kernel today is elementwise or a small stencil with
    no cross-thread reduction, so there is nothing to convert. That changes if
    the roadmap's cost-volume aggregation or a separable 3D-WLS solve lands:
    those have real reductions, and they can now assume the Apple-family ops.
    Core ML on the Neural Engine (the roadmap's unresearched fusion-network
    item) also no longer needs a CPU-fallback story.
- **Vectorizing `hfWiden` / `hfNarrow` through Accelerate.** The bulk f16↔f32
  converters sit at every I/O boundary (decode, DNG, project format, GPU
  upload) and *look* like scalar loops worth replacing. They aren't: at 46 M
  elements, best of 3, the scalar loops run 4.6 ms (widen) and 4.7 ms (narrow)
  — ~10 G elem/s, i.e. memory-bandwidth-bound, because `-O` already
  auto-vectorizes them. `vImageConvert_Planar16FtoPlanarF` ties (4.5 ms), and
  the narrow direction gets **worse** (7.7 ms) because matching our clamp to
  f16's finite range needs a separate `vDSP_vclip` pass. Leave them scalar and
  portable.
- **Metal GPUDMap zero-copy upload** — see the ROADMAP item. Two findings:
  `[Float]` elements live at offset 32 past the storage base, so
  `makeBuffer(bytesNoCopy:)` can never page-align without reworking
  `ImageBuffer`'s storage; and the warp bucket is dominated by system memory
  pressure (25–49 s swings between identical-code runs on the 4–5 GB working
  set), not the ~1–2 s memcpy — re-measure on quiet hardware before investing.

## Ablation / measurement taps

- `hyperfocal-cli -v` prints phase buckets; `compare` handles differently-cropped
  outputs of the same scene (`Metrics.psnrIntersection`) — use it for
  registration A/Bs.
- Env switches: `HYPERFOCAL_SIFT_NFEATURES` / `HYPERFOCAL_SIFT_CONTRAST` /
  `HYPERFOCAL_REGISTER_MAXSIDE` (needs `HYPERFOCAL_REGISTER_FULLGRAY=1` to ablate
  above the decode scale) / `HYPERFOCAL_REGISTER_DEBUG` /
  `HYPERFOCAL_DECODE_DEBUG` / `HYPERFOCAL_SPILL_DEBUG`.
- **Registration scale floor** is `max(1200, longest/5)`: flat-1200 *failed* the
  45 MP Mac A/B, while the 1600 bound + 2000-kp cap verified quality-neutral. The
  gray-decode policy mirrors the `/5` term (see `Aligner.openCVRegisterMaxSide`
  and the `registrationDecodeMinLongest` comments).

## Interaction latency (`HYPERFOCAL_PERFLOG=1`)

Throughput is the engine's problem; *latency* is the shell's. `PerfLog`
(AppCore, compiled on every platform — the timing companion to
`MemoryFootprint`) stamps monotonic milestones to stderr behind
`HYPERFOCAL_PERFLOG=1`: `reset` names an interaction and starts its clock,
`span` brackets one piece of work, `mark` reports a milestone that arrives in
its own call stack (a view's first draw). Marks read as both a delta and a
total offset from the click, so a log answers "where did the wait go" without
Instruments.

Wired today: Start Retouching (`AppModel.enterRetouch` on the model side; the
macOS panes' first layout, colour-cube build, and first `ctx.draw`). Trigger
it without a click via the UI-test command channel's `enter-retouch` /
`exit-retouch` actions, so a measurement is repeatable and doesn't fight the
user for the screen.

**Start Retouching, measured 2026-07-29 on the Mac Studio** (Release arm64,
45 MP × 63-frame Azurite project reopened from disk so the session is
pre-warmed; driven headless over the UI-test command channel, window not
frontmost): **~1.0–1.3 s cold** (one 0.2 s outlier across four launches),
**~0.6 s on re-entry** (stable across five cycles). The split, cold:

| step | cost |
|---|---|
| `prepareForPainting` (CoW-unique ~500 MB of working pixels + depth) | 13–27 ms |
| SwiftUI update pass → `RetouchCanvas.makeNSView` | 33–62 ms |
| `makeNSView` itself, including the CI colour cube | < 1 ms |
| AppKit first layout of the swapped-in pane tree | **0.84–1.16 s** |
| 8072×5312 → 779×839 pt `ctx.draw` | **< 1 ms** |

The 2026-07-26 record this replaces (~280–380 ms cold, ~115 ms re-entry;
machine unrecorded) split the cost evenly between plane uniquing (60–170 ms)
and first layout (82–169 ms). Two things moved, in opposite directions:

- Plane uniquing collapsed to 13–27 ms — about what ~6× the memory bandwidth
  predicts, so the old numbers were *probably* the MacBook Pro (inference, not
  record; the machine-tagging rule exists because of entries like that one).
- **AppKit first layout is now the entire interaction and it grew past the
  spinner threshold** — 0.84–1.16 s cold, ~0.45 s on re-entry, on the *faster*
  machine. Whether that is a code regression since 2026-07-26 (retouch depth
  co-painting landed in between), a window-size/display difference, or the
  old measurement's machine, is exactly what the untagged record can't answer.
  Worth an A/B at commit `abc5928` on this machine before believing "left
  alone" (the old entry's conclusion) still holds — a >1 s cold entry is no
  longer below the duration where a progress spinner helps rather than
  flashes.

Still true and re-confirmed: drawing a 45 MP CGImage into a pane-sized rect
costs under a millisecond, the colour cube is ~1 ms, and the plane uniquing
stays deliberately on the click (moving it to session build would keep
~500 MB alive for every idle pre-warmed session). The brush-source pane is a
separate, already-handled wait: its aligned frame decodes asynchronously
behind the existing "Loading source…" spinner.

Fusion can now also be triggered over the command channel (`fuse` action,
added for this measurement — building the reopened-project fixture headless
needs a fuse no screen-consent AX press can supply).

The Qt shell drives the same model, so the `model:` marks work there
unchanged; its canvas has no marks of its own yet.

## The per-pixel specialization contract (read before touching a hot loop)

Cross-file generic calls don't specialize in SwiftPM per-file debug builds — that
trap cost **55×** in the warp. Use concrete-typed helpers only (see
`PortableSIMD.swift`'s header contract). On Apple `-O`, also watch for the
stdlib's generic `pointwiseMin`/`Max` staying witness-dispatched (concrete
`hfMin`/`hfMax` fixes it bit-identically; the trap is toolchain-specific and was
neutral on Swift 6.3.3/Windows).

**f16 widen/narrow is the same trap, and it is asymmetric** (measured with
`swiftc -O -emit-assembly`, Swift 6.2/arm64, 2026-07-26):

| direction | good spelling | lowers to |
|---|---|---|
| f16 → f32 | `SIMD4<Float>(Float(p[0]), Float(p[1]), …)` | `ldr d0` + `fcvtl` |
| f32 → f16 | `SIMD4<Float16>(v)` (vector init) | `fcvtn` + `str` |

The *other* spelling is bad in each direction: `SIMD4<Float>(someSIMD4Float16)`
is the stdlib's generic `init<Other: BinaryFloatingPoint>` and tail-calls an
unspecialized generic, while the scalar-element narrowing emits four separate
`fcvt`/`str` pairs with per-index overflow checks. `SIMD3` of halves never uses
`fcvtl` at all — load the RGBA quad and take `.xyz`. Always go through
`hfLoadRGBA` / `hfLoad8` / `hfStoreRGBA`.
