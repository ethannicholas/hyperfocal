# Measuring DMap against real stacks (and why the focus measure changed)

How to judge a DMap change on real photographs rather than on synthetic ground
truth, and the reference numbers to judge it against. Written after a set of
low-resolution reference stacks turned out to expose a focus-measure failure
that every existing gate scored as fine — the synth PSNR gate, the CPU↔GPU
parity gate, and `retouch-probe` all passed while DMap left most of one
stack's background out of focus.

Read this before touching the energy path in `DMapFusion`, `GPUDMap`,
`WgpuDMap`, or the regularization radii. The parameters themselves are
documented at their call sites; this is the method.

## Why the synth gate could not see it

`hyperfocal-cli synth` renders a **noiseless** scene. The focus measure was
`|∇²|` of raw luminance — a 3×3 Laplacian, so it measures the frequency band at
Nyquist. On clean synthetic input that band is pure signal and the measure is
excellent. On a real photograph that band is where sensor noise and JPEG
quantization noise live.

Measured on the `specimen` reference stack (1136×852 JPEG, 15 frames), in a
background region that resolves only in the last few frames:

| focus measure | peak / off-peak baseline |
|---|---|
| `\|∇²\|`, no denoise | **1.09** |
| `(∇²)²`, no denoise | 1.20 |
| `(∇²)²`, luminance pre-blurred σ=1 | 3.84 |
| `(∇²)²`, pre-blurred σ=1.5 | 15.2 |
| `(∇²)²`, pre-blurred σ=2 | 40.7 |

A 1.09 ratio is not a focus signal. The per-pixel argmax was noise, the
confidence gate passed it (energy magnitude was *high* — it was all noise
energy, which is why no `noiseFloor` setting could fix this), and the weighted
median averaged the noise to mid-stack: depth 7.1 where the truth was 13. The
background rendered as mush.

The fix is two lines of algorithm — square the Laplacian, and denoise the
luminance before it (`Options.focusPreSigma`). Squaring matters because every
stage downstream *pools* the energy, and pooling an amplitude lets a large
blurry area of low-level noise out-total a small genuinely sharp one.

## Both directions are real, so measure both

The denoise **costs** 0.31 dB on the synth plane, and cannot do otherwise: with
no noise to suppress, pre-blurring only discards signal. That is not a
regression to chase away — it is the one input class where the change has
nothing to win. The CI dmap floor moved 38.7 → 38.2 for this reason.

So a DMap change needs both gates:

* `Scripts/ci-gate.sh` — synth PSNR, parity, probe. Catches drift and
  CPU/GPU divergence. Blind to noise-driven failures.
* The reference sample stacks — catches what the synth cannot.

**A synth scene with sensor noise would let one gate cover both.** Until it
exists, a change that improves the synth number while degrading real stacks
will sail through CI. See the ROADMAP item.

## Scoring real stacks

The corpus and its scoring harness live **outside the repo**, with a README
covering setup, the per-stack numbers, and what to look at next. Ask the
maintainer for the location. Nine subjects — insects, flowers, mineral
specimens, a model train — each with source frames and a commercial stacker's
renders for orientation.

Score = **per-tile sharpness as a percentage of the best any source frame
achieves at that pixel**. A fusion that picked the right frame everywhere
approaches 100%; the 12×12 tile floor localizes what was left soft, which is
the number that actually moves when depth selection fails — a stack can average
well while one region is mush.

Three things this must get right, each of which produced a wrong reading first:

1. **Use a noise-robust measure for the metric too** (same σ-denoised squared
   Laplacian). With raw `|∇²|`, the max-over-frames reference is inflated by
   max-of-N noise bias — it read ~2× any single frame in a region where no
   frame resolved anything — and blurry output scored the same as sharp.
2. **Align the outputs before comparing.** Our coverage crop, the reference
   renders, and the sources all differ in size and origin. An eyeballed offset
   had x and y effectively transposed and compared different parts of the
   scene; FFT cross-correlation against a mid-stack frame is reliable.
3. **Drop tiles with no recoverable detail.** A black-backdrop stack is >50%
   such tiles, and their near-zero denominator makes the ratio noise — it
   reported a 0.0% floor on an output with nothing wrong with it.

Do not compare against the commercial outputs pixel-wise or treat matching them
as the goal — they are differently processed (sharpened, different colour
handling) and their DMap is not uniformly better than ours. They are a sanity
reference for *whether a region should have resolved at all*.

## Reference numbers (2026-07-26, mean over the nine stacks)

DMap went **86.8% → 94.2%** of best achievable; PMax was untouched at 94.2%.
The worst stack went 59.1% → 100.8%. Contributions: the focus measure +4.2
points, resolution-scaling the regularization radii +3.2.

Per-stack figures and the remaining gaps live in the corpus README (above) —
the one worth knowing here is that the gaps left are mostly *tile floor*, not
mean: two stacks match on the average while sitting ~15 points lower on the
floor, which is the signature of one region still being mis-selected rather
than a global tuning miss.

## Resolution dependence is a standing trap

`medianRadius` and `guidedRadius` are absolute pixel counts tuned on ~45 MP
stacks. Applied unchanged to a 1 MP frame, `guidedRadius` 128 spans 12% of the
frame width instead of 1.3%, and the regularizer averages correct per-feature
depth into mid-stack mush. `DMapFusion.regularizationScale` now scales both by
the frame diagonal against a 9780 px reference; it only ever scales *down*,
because the sample stacks are all small and the high-resolution direction is
unverified.

A hand sweep independently picked 3 / 20 as best on `specimen`; the diagonal
rule predicts 2.9 / 18.6. When adding a spatial parameter, ask what it means on
a 1 MP frame *and* a 100 MP one — every sample stack here is under 2 MP, and
the app's own defaults were tuned an order of magnitude above that.
