# Engine performance notes

Living reference for fusion-performance work: where the time goes, what has been
tried and rejected, and how to measure. ROADMAP.md keeps the forward *goal*
(hit the throughput bar); the data and dead-ends live here so the roadmap stays
skimmable.

## Measurement environment

Numbers below come from the 2-core / 8 GB ARM64 dev VM (details in the
build-machine notes) and are **relative, not absolute** — perf targets are
hardware-relative (the bar is commercial-stacker speed on the *same* machine),
and real hardware will differ. The VM also drifts slower over a long session, so
only interleaved A/Bs settle close calls.

Sampling profilers can't run in the VM (the hypervisor doesn't virtualize the
profiling interrupt — WPA/VS/Superluminal all need it); use instrumented
decomposition (phase buckets + scratch benches). On real Windows hardware,
`wpr` + WPA symbolize with `swift build -Xswiftc -debug-info-format=codeview
-Xlinker /DEBUG`.

## Throughput bar

**< 2 min end-to-end** on the reference stacks (measured against commercial
stackers on the VM). pmax is close; dmap has further to go.

### 11 MP reference — 82 × 11 MP JPEGs: dmap ~175 s, pmax ~132 s

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

### 45 MP reference — 10 × 45 MP DNG (`~/Desktop/Fluorite`): dmap ~295 s

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
  but small on Apple Silicon — 12 MP × 17 synth, best of 2: dmap/cpu 7.06 → 7.41 s
  (+5 %), pmax/cpu 5.84 → 6.52 s (+12 %). The GPU paths, which are the default
  engine, got *faster* on the same stack (dmap 5.36 → 3.94 s, pmax 4.02 → 3.35 s)
  — half the bytes through every kernel. Peak footprint fell ~25 % across all
  four combinations (e.g. dmap/gpu 2.45 → 1.83 GB); it is not 50 % because
  decode buffers, the scalar f32 planes, and the Metal/OS baseline don't scale
  with pixel storage.
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
  and round their weighted averages the same way. Worth re-measuring against
  Metal's warped end-to-end dmap on a Mac — the ≥90 re-baselining was done on the
  unwarped case only.
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

**Start Retouching, measured 2026-07-26** (Release arm64, M-series, 42 MP ×
63-frame Azurite project reopened from disk, so the session is pre-warmed):
**~280–380 ms cold, ~115 ms on re-entry.** The split, cold:

| step | cost |
|---|---|
| `prepareForPainting` (CoW-unique ~500 MB of working pixels + depth) | 60–170 ms |
| SwiftUI update pass → `RetouchCanvas.makeNSView` | 10–22 ms |
| `makeNSView` itself, including the CI colour cube | < 5 ms |
| AppKit first layout of the swapped-in pane tree | 82–169 ms |
| 8076×5237 → 575×764 pt `ctx.draw` | **< 1 ms** |

Both suspects the roadmap had flagged are non-issues: drawing a 42 MP CGImage
into a pane-sized rect costs under a millisecond (CoreGraphics' downsample is
not on anyone's critical path), and building the 64³ colour cube costs 1–6 ms.
The real cost is evenly split between the plane uniquing — which is
deliberately on the click, because moving it to session build would keep
~500 MB alive for every idle pre-warmed session — and AppKit laying out the
replacement view tree. Neither has a cheap fix, and a few hundred
milliseconds is below the duration where a progress spinner helps rather than
flashes, so this is left alone. The brush-source pane is a separate,
already-handled wait: its aligned frame decodes asynchronously (~2.5 s on a
cold session) behind the existing "Loading source…" spinner.

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
