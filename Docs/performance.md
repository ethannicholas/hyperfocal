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

- **M5 Max** — Apple M5 Max, 18-core CPU (12 P + 6 E), 128 GB unified memory.
  macOS 26.6 as of 2026-08-11. Far wider and deeper than anything else in the
  roster, which makes it the machine that finds *constant* caps: several
  engine limiters were written when no machine here could reach them, so they
  had never been the binding term before. Read its absolutes as a ceiling, not
  as a user's experience — the low-end floors in those formulas still matter
  and are still tested (see the 8 GiB entries in `FramePrefetcher` and
  `AppModel.eagerCompletionFits`).
- **Mac Studio** — Mac Studio (2022, Mac13,1): Apple M1 Max, 10-core CPU
  (8 P + 2 E), 24-core GPU, 64 GB unified memory. macOS 26.5 as of
  2026-07-29.
- **MacBook Pro** — MacBook Pro (14-inch, 2021, MacBookPro18,3): Apple M1
  Pro, 8-core CPU (6 P + 2 E), 14-core GPU, 16 GB unified memory (~200 GB/s).
  macOS 26.5 as of 2026-07-29. **Not** the plain M1 (~4 P cores, ~68 GB/s)
  older notes had inferred — any bandwidth arithmetic done against that guess
  is off by ~3×.
- **Windows Desktop** — 8-core / 16-thread Zen 4, 32 GB, Windows 11. GPU:
  **NVIDIA GeForce RTX 4080 SUPER, 16 GB** (wgpu reaches it through the Vulkan
  backend), recorded 2026-08-06. *(Exact CPU model still to be filled in.)*
- **ARM64 dev VM** — Windows-on-ARM VM, 2 cores / 8 GB, no real GPU (WARP
  only). Numbers from it are **relative, not absolute** — perf targets are
  hardware-relative (the bar is commercial-stacker speed on the *same*
  machine). The VM also drifts slower over a long session, so only interleaved
  A/Bs settle close calls. Retired for new measurements once the Windows
  Desktop arrived (2026-07-28).

Historical caveat: Apple numbers gathered **before 2026-07-29** never recorded
which machine (MacBook Pro or Mac Studio) produced them, so they bound the M1
*family*, not a machine. Where such a number survives below it is marked
"machine unrecorded"; current Apple absolutes live in the Mac Studio and
MacBook Pro reference sections.

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

### 45 MP reference — 10 × 45 MP DNG stack: dmap ~295 s (ARM64 dev VM, pre-2026-07-28)

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

The MacBook Pro retake (reference section below, 2026-07-29) then resolved the
attribution — but weakened the parity read. The old entry's figures line up
with the MacBook Pro's *wall clocks* (7.16 s dmap/cpu, 6.54 s pmax/cpu; all
four configurations land within 10 %, three within 4 %), not with any fuse
subtotal, so
"7.88 vs 7.41" compared this desktop's fuse subtotal against a number that
included ~1.7 s of registration. Like for like, the M1 Pro's CPU fuse
subtotals are 4.87/4.46 s against this desktop's 7.88/7.51 — the laptop leads
~1.6–1.7×.

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

## Half storage on the wgpu backend (Windows Desktop, 2026-08-06)

The WGSL kernels were f32 while `ImageBuffer` and the Metal kernels were f16,
so `WgpuDMap`/`WgpuPyramid` widened through an f32 staging array at every
host↔device RGBA transfer. Porting them to half storage (`pack2x16float` /
`unpack2x16float` — core WGSL, so no `shader-f16` feature is required, which
matters because the validated software surfaces can lack it) removes both the
conversion pass and half the transfer bytes. The f32 exceptions are the ones
Metal already carries and for the same reasons: the separable blur's H→V
intermediate, `pyr_upsample`'s output (the band is a difference of two
near-equal Gaussians — cancellation), and the tent/base accumulators.

**Measure the fuse subtotal, not wall clock**: registration is unchanged by
this and dominates at these sizes. Synth stacks (TIFF), `-v`, sizes are the
common-coverage canvas after registration.

| stack | dmap f32 | dmap **f16** | pmax f32 | pmax **f16** |
|---|---|---|---|---|
| 45 MP × 11 (8110×5409) | 17.93 s | **13.85 s** | 13.16 s | **12.41 s** |
| 100 MP × 9 (11881×7920) | 33.66 s | **26.49 s** | 25.15 s | **23.96 s** |

**DMap gains ~21–23%; PMax gains ~5%, and the phase split says why** — PMax's
upload cost was already hidden behind decode, so removing it just exposes more
decode wait:

| pmax phase | 45 MP f32 → f16 | 100 MP f32 → f16 |
|---|---|---|
| decode-wait | 6.98 → **9.14 s** | 14.87 → **18.33 s** |
| upload | 3.53 → **0.81 s** | 5.86 → **1.59 s** |
| GPU compute | 0.46 → 0.51 s | 0.28 → 0.30 s |

Upload dropping ~4× (not 2×) is the widening pass disappearing on top of the
halved bytes. DMap benefits where PMax doesn't because it round-trips frames
through the host per frame (exposure mean, spill, previews) rather than
streaming one way.

**Peak device memory, 100 MP** — sampled device-wide at 200 ms above a 1230 MB
idle baseline, because WDDM reports no per-process figure through `nvidia-smi`:

| method | f32 | **f16** |
|---|---|---|
| pmax | 14705 MB | **9636 MB** |
| dmap | 9212 MB | **6685 MB** |

That is the result worth keeping: **the f32 path was within ~1.6 GB of filling
a 16 GB card at 100 MP**, so it was the pixel count, not the algorithm, that
bounded what this backend could fuse. The drop is 27–34% rather than 50%
because the f32 planes (winner energies, grit, focus tracks), the f32 upsample
scratch and the base accumulator don't scale with pixel storage — the device-
side mirror of the ~25%-not-50% finding host memory showed when `ImageBuffer`
went f16.

Host peak RSS is unchanged (7.2–7.3 GB at 45 MP, 15.0–15.2 at 100 MP, before
and after): the staging arrays this removed were never the host peak — decode
buffers are.

**The store's rounding mode is backend-dependent, and getting it wrong costs
~30 dB.** `pack2x16float` looks like the obvious way to narrow, and it is on
Vulkan and Metal (round-to-nearest-even, matching Swift's `Float16(x)`). The
D3D12 backend lowers it to HLSL `f32tof16`, which **truncates**, so every
stored pixel lands up to one ulp low — systematically, in every kernel that
writes a pixel. Measured on WARP (`HYPERFOCAL_WGPU_FALLBACK=1
HYPERFOCAL_WGPU_SOFTWARE=1 hyperfocal-cli debug-wgpu`), with the load side
unaffected — a signature worth recognizing, since only store-side kernels move:

| kernel | pack2x16float on D3D12 | explicit RTNE |
|---|---|---|
| `warp_lanczos3` | 72.1 dB | **100.3 dB** |
| `pyr_blur5_h+v` | 71.4 dB | **inf** (bit-identical) |
| `pyr_select` | 75.0 dB | **inf** |
| `normalize_out` | 21.3 dB | **inf** |
| suite minimum | **21.3 dB** (floor 90) | **100.3 dB** |

`normalize_out` is worst because it divides by a small weight sum, so a
one-ulp store error rides on a large value. `h4store` therefore narrows with
an explicit round-to-nearest-even routine on every backend rather than the
builtin — **do not "simplify" it back**. It costs nothing measurable: the
GPU-compute bucket moved 0.46 → 0.51 s at 45 MP and 0.28 → 0.30 at 100 MP
(both noise beside a 12–26 s fuse), because these kernels are memory-bound.
The load side keeps `unpack2x16float`: f16→f32 is exact everywhere.

This is also the reason the software adapter is worth running on purpose. No
Windows machine with a working Vulkan driver selects D3D12, so a discrete-GPU
run never sees this; CI's llvmpipe is Vulkan and would not have seen it
either.

**Quality is unmoved and parity improved.** Against synth truth, f32 vs f16:
54.51 / 54.51 dB (45 MP dmap), 53.70 / 53.72 (45 MP pmax), 55.91 / 55.92 and
55.45 / 55.54 (100 MP). The two engines' own outputs agree at 82.2 dB (dmap)
and 69.6–70.7 (pmax), the band f16 storage implies. In `debug-wgpu` on the
discrete GPU, warped dmap went **74.0 → 100.1 dB** (depth 66.8 → 103.4) and
retired its relaxed floor, fusion minimum 69.6 → 72.5, and five kernels became
bit-identical; the 94.9 dB kernel minimum is unchanged because it is the warp
kernels, which were already compared as f16 on both sides. On WARP the same
suite reads 100.3 dB minimum, dmap 118.0 plain / 101.7 warped — *higher* than
the discrete GPU, because a software rasterizer does not reassociate the way a
real one does.

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

## Apple reference (MacBook Pro, 2026-07-29)

Same synth shapes, same day, same code as the Mac Studio section, taken so
both development Macs have tagged absolutes. Wall clock is the whole `fuse`
process including registration and export; best of 3 at both sizes. Two
context caveats: the machine was on AC power with the user's normal desktop
session running (not freshly quiet), and 16 GB of memory is close to the
45 MP working set — 12 MP spread was ≤ 3 %, but 45 MP spread ran to ~25 %
(dmap/gpu 12.10–16.41 s across three runs), so read the 45 MP row as
indicative, not precise.

| stack | dmap cpu | dmap gpu | pmax cpu | pmax gpu |
|---|---|---|---|---|
| 12 MP × 17 (4240×2832 TIFF) | 7.16 s | 3.56 s | 6.54 s | **3.23 s** |
| 45 MP × 11 (8192×5464 TIFF) | 19.63 s | 12.10 s | 17.84 s | 12.39 s |

(At 45 MP the two GPU configurations tie within the run-to-run spread.)

Phase split at 12 MP (`-v`, best run):

| phase | dmap cpu | pmax cpu | pmax gpu |
|---|---|---|---|
| registration (CPU, before fuse) | 1.72 s | 1.74 s | 1.76 s |
| decode | 0.12 s | 0.12 s | 0.12 s wait |
| warp | 2.32 s | 2.25 s | — (on device) |
| energy / build + select + collapse | 1.20 s | 1.85 s | — |
| upload | — | — | 0.07 s |
| **GPU compute** | — | — | **0.60 s** |
| **fuse subtotal** | **4.87 s** | **4.46 s** | **1.12 s** |

(dmap cpu's remaining buckets total 1.14 s. dmap gpu fuse subtotal: 1.28 s.
Peak memory at 12 MP: 3.3–3.9 GB; at 45 MP: 6.1–7.5 GB.)

Read against the Mac Studio:

- **Registration is identical — ~1.7 s at 12 MP on both machines.** The extra
  performance cores and doubled bandwidth buy nothing here, so Vision's cost
  is effectively serial per frame pair; it is 54 % of pmax/gpu's wall on this
  machine. The "cheaper feature detector" prize is the same prize on every
  machine in the roster.
  - **Correction (M5 Max, 2026-08-11): the "effectively serial" inference was
    wrong, and this measurement could not have seen otherwise.** Both machines
    were pinned at 4 registration workers by a constant cap in
    `Aligner.registrationConcurrency`, so the constant ~1.7 s was the cap, not
    Vision — and the cap is exactly why the extra cores bought nothing. Lifted
    to core count, registration scales nearly linearly (see the section below).
    The detector prize is real and unchanged in kind, but it is no longer
    54 % of wall on a wide machine.
- **CPU fusion: the M1 Max leads the M1 Pro only ~1.25–1.3×** (fuse subtotals
  3.79/3.50 s vs 4.87/4.46 s) despite 2× the memory bandwidth and 8 P cores
  vs 6 — consistent with the Windows section's finding that the CPU path is
  compute-bound, not bandwidth-bound. This laptop still leads the Zen 4
  desktop ~1.6–1.7× like for like.
- **GPU compute scales sublinearly with core count**: pmax GPU compute is
  0.60 s here vs 0.43 s on the 24-core Mac Studio (14 cores, 1.4× time for
  0.58× cores) — the kernels are too small at 12 MP to fill either device.
  Upload is the same 0.07 s (unified memory on both).
- **At 45 MP the gap widens to 1.35–1.8×** (19.63/12.10/17.84/12.39 s vs the
  Studio's 14.33/7.95/13.19/7.04) and run-to-run spread grows an order of
  magnitude. Peak memory reads 6.1–7.5 GB against the Studio's 12.9–13.3 GB
  for identical work — consistent with the engine's memory-proportional
  spill/batching sizing itself to the machine, so peak-memory figures in this
  file are machine-relative, not workload constants.
- **CPU↔GPU fused-output agreement is identical to the Mac Studio to the
  tenth of a dB**: dmap 95.6 dB (12 MP) / 101.1 dB (45 MP), pmax 70.6 / 70.9.
  Two different M1-family GPUs producing the same parity numbers says the
  band is a property of the code and the architecture family, not the
  individual machine.
- **The machine-unrecorded M1-family entry is resolved: it was this laptop,
  measuring wall clock.** Its post-f16 figures (7.41/6.52 s cpu, 3.94/3.35 s
  gpu) land on today's MacBook Pro walls (7.16/6.54, 3.56/3.23) — three of
  four within 4 %, dmap/gpu within 10 % (Metal-side work has shipped since)
  — and match no fuse subtotal on either Mac. See the correction in the
  Windows Desktop section.

## Registration concurrency: the cap was the cost (M5 Max, 2026-08-11)

`Aligner.registrationConcurrency` was `min(4, cores − 1)`. The 4 was
historical; the `min` existed only to keep a 2-core VM usable. On every machine
in the roster up to this point the 4 was the binding term — and because it was
a *constant*, registration measured the same on an 8-core M1 Pro and a 10-core
M1 Max, which the MacBook Pro section read (wrongly) as Vision being serial.

Interleaved A/B on the 12 MP × 17 synth stack, `HYPERFOCAL_REGISTER_WORKERS`
sweeping the outer fan-out, best of 3, registration wall only:

| workers | 1 | 2 | 4 | 8 | 12 | 16 | 18 |
|---|---|---|---|---|---|---|---|
| registration | 2.99 s | 1.70 s | 1.10 s | 0.83 s | 0.69 s | 0.70 s | 0.56 s |

5.3× serial→18, and **1.97× against the old cap of 4**. The flat step at 12–16
is wave quantization, not saturation: 17 work units over 16 workers is one full
wave plus a straggler, so the reading is "scales to the core count", not "peaks
at 18". Both passes parallelize — per-frame decode+gradient+detect, then
per-pair matching — through the same `boundedConcurrentMap`.

End-to-end, old cap vs the new default (17 here), best of 3:

| stack | wall @4 | wall @default | registration | peak memory |
|---|---|---|---|---|
| 12 MP × 17 (4240×2832 TIFF) | 1.84 s | **1.29 s** (−30 %) | 1.12 → 0.57 s | 3.93 → 4.36 GB |
| 45 MP × 11 (8192×5464 TIFF) | 4.34 s | **3.36 s** (−23 %) | 2.25 → 1.25 s | 12.94 → 13.87 GB |

Fused output is **byte-identical** at every worker count (`cmp` across 4/8/12/17
at 45 MP) — results are collected by index, so concurrency cannot reorder them.

The per-worker memory cost is ~115 MB at 45 MP (peak 12.95 → 13.87 GB going 4 →
12 workers), i.e. the full-res gray plane plus its decode transient; only the
gradient plane (~1/16 of the float image) is retained. The replacement formula
is `min(cores − 1, physicalMemory / 1 GiB, registrarFanOutCeiling)` — the memory
term carries ~8× headroom over that measurement and exists to pull small
machines down, not to shape this one. A 2-core VM still resolves to 1, unchanged.

### …but almost none of it is there on RAW, and the naive version costs 4 GB

The synth stacks above are TIFF. On the **78 × 45 MP NEF reference stack**
(Fluorite 2, M5 Max, 2026-08-11) the same sweep is *flat* — registration there
is entirely decode-bound, and CIRAW is internally parallel, so the workers
contend instead of scaling:

| workers | 2 | 4 | 8 | 12 | 17 |
|---|---|---|---|---|---|
| registration | 22.93 s | 23.27 s | 22.84 s | 22.56 s | 22.57 s |
| peak memory | 8.67 GB | 8.82 GB | 10.51 GB | 10.80 GB | 13.22 GB |

3 % of time for 53 % more peak memory. This is the same fact
`FramePrefetcher.workers(for:)` already records about the same decoder, arrived
at from the other direction — so `registrationDecodeConcurrency(for:)` defers to
it rather than restating it, and registration's **decode** pass is held to 2 on
Apple RAW while its **pair-matching** pass keeps the full fan-out (it decodes
nothing, so RAW is irrelevant to it). Splitting the two passes keeps the TIFF
win and drops the RAW cost instead of trading one against the other.

Re-confirmed after the split, interleaved: peak 9.88/9.91/9.14 GB capped vs
13.25/13.23 GB uncapped. **The timing half of that A/B is not recorded here** —
the machine had picked up a load average near 9 by then and registration
scattered over 22–73 s per run regardless of configuration. Peak memory is
load-independent, so it stands; the time figures in the table above are from the
quiet window earlier the same day. If you re-measure, check `uptime` first.

The general shape worth carrying forward: **a fan-out win measured on TIFF does
not transfer to RAW**, because the two decode paths have opposite concurrency
behavior. Any future "widen this pass" change wants both input classes measured
before it ships, and the memory column is as much a result as the time column.

**This lands on the Vision path only; OpenCV keeps the 4.** Vision is one call
per pair with no thread pool of its own, which is why it scales. OpenCV's SIFT
detect is internally parallel, so N concurrent detections oversubscribe N× —
mechanically a different question, and unmeasured. It could not be settled on
the machine that found the Vision win: the macOS OpenCV A/B needs
`HYPERFOCAL_OPENCV_AB=1` at build time *and* a pkg-config'd OpenCV, and with
neither present `HYPERFOCAL_REGISTER=opencv` is **silently ignored** — a sweep
that appears to exercise OpenCV and in fact re-measures Vision. (Confirmed the
hard way: the "OpenCV" column came back matching Vision to the millisecond at
every worker count.) If you run that A/B, check first that the binary really
has the backend compiled in. Windows/Linux measurement is a ROADMAP item; the
prize there is the same ~2×, against registration's 51 % of x64 wall clock.

**The general lesson, worth applying to the rest of the file:** a limiter that
is a constant rather than a formula stops being visible as a limiter the moment
it binds, and every measurement taken past that point silently describes the
cap. Two other constants are in the same position and have not yet been
re-measured — `FramePrefetcher.defaultLookahead`'s trailing `8` and
`FramePrefetcher.workers(for:)`'s Apple-RAW `2`.

## Decoding the stack once instead of twice (M5 Max, 2026-08-12)

Registration decodes every frame, then fusion decodes every frame again. For
RAW that second decode is pure waste, because the first one already produced
exactly what fusion wants: `ImageFile.loadGray8CGImage` has no cheap route to
luminance on a RAW file, so it calls `loadRAW` — full RGBA f16 — and discards it
to keep 1/16th as gray. `DecodedFrameCache` carries those buffers across the
registration→fusion boundary instead.

Reuse is exact, not approximate: registration's RAW path and fusion's
`ImageFile.load` both call `ImageFile.loadRAW(url:)`, deterministic per file.
Verified — fused output is **byte-identical** (`cmp`) with reuse on and off, for
both methods.

78 × 45 MP NEF reference stack, interleaved, `HYPERFOCAL_DECODE_REUSE` as the
budget in MB (0 disables), 2 reps, spread under 1%:

| method | budget | wall | decode-wait | peak memory |
|---|---|---|---|---|
| dmap | off | 47.1 s | 15.2 s | 9.78 GB |
| dmap | 16 GB | **37.4 s** (−21%) | **5.8 s** (−62%) | 24.1 GB |
| pmax | off | 44.8 s | 19.6 s | 9.89 GB |
| pmax | 16 GB | **35.5 s** (−21%) | **7.8 s** (−60%) | 24.1 GB |

At 16 GB the cache holds 47 of 78 frames (363 MB each), so ~60% of the second
decode disappears and the win tracks that fraction — a 4 GB budget caches 11
frames and buys only ~5%. Peak memory is predictable: baseline + budget.

The budget is `physicalMemory / 8`. The tight moment is the boundary itself,
where the cache is fullest and fusion is starting to allocate on top; it drains
from there. Sized in bytes rather than frames because frame size varies ~30×
across the stacks we handle.

**Windows and Linux are unaffected by construction**, which also means the 8 GB
OOM history recorded elsewhere in this file is not in play: the CImaging path
decodes gray directly and never materializes an RGBA buffer, so there is nothing
already-paid-for to hand back and the cache stays empty. Same for non-RAW on
Apple. The rule is "never discard what we already made", never "make it early" —
a cache that *caused* a decode would be a pessimization on every input class
that has a cheap gray path.

**There were six decode seams, not one.** `StackSource.frame(at:)` looks like
the funnel and is not: the GPU pyramid engines warp on the device, so they
deliberately bypass the warping accessor and open-code
`ImageFile.load(url: source.urls[i])` — `PyramidFusion`, `DMapFusion`, and both
passes each of `GPUDMap` and `WgpuDMap`. The first cut of this change wired only
the funnel; the cache filled correctly, was never read, and cost 16 GB for a 7%
*slowdown*. The tell was decode-wait not moving (18.3 → 19.9 s) while the cache
reported itself full — a cache that populates but never hits looks exactly like
a cache that isn't there, plus the memory. They now share
`StackSource.decodedFrame(at:)`, which is the seam that should have existed.

## Measured dead ends (don't re-try without new hardware or evidence)

- **Registering Vision below full resolution (M5 Max, 2026-08-11).** The most
  attractive-looking RAW win on the board, and it fails on quality, decisively.
  The setup: `ImageFile.loadGray8Registration` on Apple ignores its `minLongest`
  / `scaleFloorDenom` arguments and full-decodes, so Vision registers 45 MP
  gradients while the CImaging path has always registered a reduced decode. A
  full mosaic decode costs ~0.95 s/frame on 45 MP NEF — **9.5 s of a 20 s fuse**
  on the 78-frame reference stack — whereas `CGImageSourceCreateThumbnailAtIndex`
  returns the 1651 px image registration consumes in **0.061 s**, ~15× cheaper.
  `ImageFile.thumbnail` has documented that fast path for display previews all
  along; registration simply never used it.
  Implemented (decode at the bound, `RegistrationFrame` carrying its scale on
  both platforms, `upscaleHomography` mapping the fit back) it is a large,
  real speedup — 12 MP synth registration 3.31 → 0.94 s, 45 MP 6.16 → 2.13 s —
  and it costs **6–7 dB against ground truth**:

  | stack | full-res (today) | at the registration bound |
  |---|---|---|
  | 12 MP × 17 synth, dmap vs truth | 51.92 dB | 45.60 dB |
  | 45 MP × 11 synth, dmap vs truth | 57.77 dB | 50.69 dB |

  There is no knee to settle on. Sweeping the 12 MP scale gives 45.60 / 44.95 /
  46.25 / 47.03 / 47.91 / **51.92** dB at 1000 / 1500 / 2000 / 2500 / 3000 /
  4240 (full) — monotonic in scale, with the largest single step at the last
  one, i.e. between "resampled at all" and "not resampled".
  Not an implementation bug: zero Occam-gate rejections at every scale (a
  mis-mapped homography would show up there and would collapse PSNR far below
  45 dB, not shave 6 off it), and the crop offsets move by only a few pixels.
  **The transferable finding is that the two registrars have opposite
  scale sensitivity.** OpenCV SIFT was measured quality-neutral at this very
  bound (the 1600 + 2000-kp A/B, 2026-07-20), which is why the bound exists;
  Vision is not, and reasoning from one to the other is how this looked safe.
  Anything that reduces what Vision sees needs its own ground-truth A/B —
  `hyperfocal-cli synth` at 4240×2832 or larger, since the CI gate's 900 px
  synth sits below the bound and cannot see this class of regression at all.
  The RAW decode cost is real and still worth attacking; the remaining route is
  the double decode (registration's gray pass and fusion's full pass decode the
  same file separately), which leaves what Vision sees untouched. See ROADMAP.

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
  below these. The MacBook Pro retake (2026-07-29) settled the attribution:
  today's MacBook Pro *wall clocks* land within a few percent of this entry's
  post-change figures in all four configurations, so this entry was the
  MacBook Pro, and its figures were wall clocks (registration included), not
  fuse subtotals.
- **Quantizing the wgpu warp output to f16 on-device — a dead end that was
  local, not general, and the distinction cost a bar for a week.** The move was
  to make the wgpu backend carry byte-identical halves to the CPU
  (`pack2x16float`/`unpack2x16float`, core WGSL — no `shader-f16` feature
  needed), motivated by CPU↔wgpu dmap parity splitting by variant once pixel
  storage went f16: unwarped 106.3 dB, warped **78.2 dB** against a 90 dB bar
  (WARP, 9 × 360×240 synth plane scene). Quantizing *only the warp output* made
  it **worse — 78.2 → 70.7 dB** (pyramid_warp 68.7 → 67.5), so it was reverted
  and the warped variant was given its own relaxed floor. **The conclusion
  drawn from that — "the residual is intrinsic to f16 storage" — was wrong**,
  and the full half-storage port (2026-08-06) refuted it: with *every* RGBA
  buffer in the chain f16, warped dmap measures **100.1 dB** (depth 103.4) on a
  discrete GPU, past the 90 dB bar, and the relaxed floor is gone. What the
  narrow experiment actually showed is that quantizing at one seam is worse
  than not quantizing at all — downstream kernels then read values the CPU
  never held, and dmap's argmax amplifies a full-ulp disagreement into a whole
  frame-index flip. Consistency across the chain is the property that matters,
  not matching the CPU at any single point. Corroborating figure that should
  have carried more weight at the time (Mac Studio, 2026-07-29): Metal's warped
  end-to-end dmap agreement is 95.6 dB at 12 MP / 101.1 dB at 45 MP — Metal
  never had the asymmetry, so its clearing 90 was evidence the gap was
  removable, not evidence that f16 imposed it.
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
- Env switches: `HYPERFOCAL_DECODE_REUSE` (registration-decode cache budget in
  MB; `0` disables) / `HYPERFOCAL_SIFT_NFEATURES` / `HYPERFOCAL_SIFT_CONTRAST` /
  `HYPERFOCAL_REGISTER_MAXSIDE` (needs `HYPERFOCAL_REGISTER_FULLGRAY=1` to ablate
  above the decode scale) / `HYPERFOCAL_REGISTER_WORKERS` (registration
  fan-out — the sweep above) / `HYPERFOCAL_REGISTER_DEBUG` /
  `HYPERFOCAL_DECODE_DEBUG` / `HYPERFOCAL_SPILL_DEBUG`.
- wgpu adapter selection: `HYPERFOCAL_WGPU_SOFTWARE=1`
  *permits* auto-selecting a software adapter, and `HYPERFOCAL_WGPU_FALLBACK=1`
  *requests* one (`forceFallbackAdapter` — D3D12 WARP, llvmpipe) even on a
  machine with a discrete GPU. Use both together to reproduce the surface CI
  gates `debug-wgpu` on; software validates correctness, never speed.
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
a 45-megapixel, 63-frame stack's project reopened from disk so the session is
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

- Plane uniquing collapsed to 13–27 ms. This was first read as "about what
  ~6× the memory bandwidth predicts, so the old numbers were probably the
  MacBook Pro" — but the roster now records that machine as an M1 Pro
  (~200 GB/s, 2026-07-29), so bandwidth predicts only ~2× and the arithmetic
  behind that attribution is gone. The laptop attribution itself is still
  plausible (the fuse-matrix entries *were* traced to it — see the MacBook Pro
  reference section), but for this measurement it stays inference until Start
  Retouching is retaken on the MacBook Pro; the machine-tagging rule exists
  because of entries like this one.
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
