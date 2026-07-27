# Measuring rim quality (despill / debloom / halo work)

How to judge a change to the rim-glow passes objectively, and the reference
geometry and acceptance numbers to judge it against. Written after the rim
despill, the PMax-native despill gate, and the debloom near-black gate — all
three were decided by these measurements, and two of them were nearly decided
*wrongly* by skipping the last section.

Read this before touching `Despill.swift`, `BlackPoint.swift`, or the focus gate
in `PyramidFusion.swift`. The env knobs themselves are documented at their call
sites; this is the method, not the API.

## The problem with looking

The artifacts live in the dark background beside a subject's silhouette, at
values of a few hundred to a few thousand out of 65535. At normal brightness
they are invisible; at heavy shadow lift everything looks broken. Eyeballing
crops produced a wrong call more than once, and patch means over a region hide
the thing being measured — the artifact is a *profile*, a few px wide, and a
mean over 20 px flattens it into the background.

## Edge-anchored profiles

Sample along a line crossing the silhouette, but index the samples from the
**edge itself**, not from an absolute coordinate:

1. Walk the line until the 5-px-wide running mean of the 16-bit gray crosses
   **20000** — that is the silhouette.
2. Report values at fixed distances *outside* that crossing (6, 10, 20, 30, 50,
   80 px at full res), each a 5×5 patch mean.

Anchoring to the edge makes the numbers immune to canvas offsets, so a
Hyperfocal fuse, a Helicon export, and a re-fuse on a different crop are
directly comparable without registering them. It also means the *shape* of the
falloff is visible: a healthy result decreases monotonically outward, a
dark-halo artifact shows a trough, and an over-subtraction shows a moat (values
at or near zero inside a few px of the edge).

Script: see the end of this file.

## Reference geometry

- **Azurite** (`~/Desktop/Azurite`, 63 NEF/DNG): fused canvas **8076×5237**.
  Test columns **x = 3350, 3410, 3470, 3530**, scanning down from y≈1200 for the
  edge of the white matrix rock.
- **Helicon reference** — a Helicon Focus export of the same stack, 8254×5502,
  sitting at **+90 in x, +133 in y** relative to our canvas (add +90 to a column
  when probing it). Earlier sessions measured its background carrying a uniform
  veil ≈ **240** above ours; subtract that before comparing absolute levels, or
  compare shapes. **The file is not in the repo and no longer on the Desktop**,
  so the table below is the surviving record of it — re-export from Helicon
  Focus if a new comparison is needed, and re-derive the offsets if you do.
- **sample-stack** (`~/Desktop/sample-stack`, 82 JPEG, 4096×2731): fused canvas
  **3888×2601**. Purple fluorite + cream barite on **white marble** — the
  inverted-contrast case, where the subject is *darker* than the background.
  Keep it: it is the only stack in hand that breaks assumptions built on
  dark-backdrop specimens.
- **Fluorite** (`~/Desktop/Fluorite`): specular-bokeh check. Glints must not
  change (57 dB was the shipped despill's result).
- **Fluorite 2** (`~/Desktop/Fluorite 2`, 78 NEF): fused canvas **8031×5357**.
  Purple fluorite + cream calcite on black — the stack that showed the halo
  "around almost the entire specimen" at default settings and drove the
  always-on render cleanup. The calcite's right rim is probed with *horizontal*
  scans (rows y = 2200, 2600, 3000, 3400, scanning right-to-left; report
  distances to the right of the edge); the top edge with column scans at
  x = 3000, 3600, 4400. Helicon reference: `~/Desktop/Fluorite 2 Helicon.tif`
  (8254×5502; its background is true 0 past ~10–30 px everywhere, and it keeps
  a physical rim tail of ~17k/17k/10k at −6/−10/−20 at the calcite's bottom
  contact, so a tail of that scale near y≈3400 is *matching* it, not failing).
  Defaults-on cleanup measured: calcite row y=2200 went 6141 → 78 at −10 px
  (reference ~0); the wide 20–30 px band matches the reference everywhere.
  With the rim-adjacency gate relaxation the top-edge residual was ~2k at
  −6/−10 vs the reference's ~70–335 — accepted at the time as guided-filter
  smoothing, then shown to be visible at normal brightness and eliminated by
  the per-pixel floor (2026-07-26 entry below): the band now measures 100–500
  at −10/−15/−20 across all seven probe columns, at or under the reference.

## Acceptance numbers

**Azurite rim, full res** (16-bit gray), the Helicon reference at every tested
column and distance — matching within ~2× is the bar:

| column | −6 | −10 | −20 | −30 | −50 | −80 |
|---|---|---|---|---|---|---|
| x=3350 | 2316 | 864 | 477 | 300 | 255 | 155 |
| x=3410 | 1855 | 1074 | 439 | 352 | 332 | 286 |
| x=3470 | 1569 | 852 | 553 | 379 | 319 | 301 |
| x=3530 | 1350 | 823 | 498 | 339 | 177 | 220 |

Shipped PMax debloom + despill measured `1946 / 871 / 686 / 492 / 372 / 134` at
x=3350 — i.e. on the reference from −10 outward, slightly under it at −6.

**sample-stack**, two single-number metrics that caught the debloom regression:

| metric | how | no debloom | DMap | bad debloom | fixed |
|---|---|---|---|---|---|
| fluorite halo | luminance at (2500, 623) − (2500, 650); edge at y=663. **Positive = dark halo** | −1124 | −405 | +1908 | +337 |
| barite saturation | RGB at (710, 1060), `(max−min)/max` | 0.26 | 0.25 | 0.15 | 0.25 |

Plus, always: the subject must be untouched. Compare a like-for-like baseline
(**same engine** — a CPU-vs-GPU comparison will show ~79 dB of engine
difference and drown the signal) and confirm the body region is bit-exact and
that no pixel got *brighter*, since these passes only ever subtract.

## Tooling

- `fuse … --color-space p3` for anything being measured, so the loaded image
  matches the working buffer the grid inputs were built from.
- `HYPERFOCAL_DESPILL_DUMP=<dir>` on a dmap fuse writes the grid inputs
  (`perCellFloor.f32`, `spillStrength.f32`, `meta.txt`).
- `debug-despill --dump <dir> --image <any fused image> --output <out>` applies
  the pass in seconds without re-fusing. It takes *any* image, which is how
  "would despill help PMax?" was answered before writing a line of PMax code —
  feed it a PMax fuse with DMap's dumped gate and you have an upper bound.
- Plane dumps for the gates: `HYPERFOCAL_DUMP_SPILLW` / `_SPILLD` (despill),
  `HYPERFOCAL_DUMP_LUMMIN0` / `_NEARBLACK` (debloom's near-black gate). They
  write raw f32 at grid or full resolution; read with
  `numpy.fromfile(..., dtype=numpy.float32).reshape(h, w)`.

## Measured tuning boundaries (don't re-derive these)

- **Despill spill gate `SPILL_LO` 0.42 → 0.30 globally** was measured on
  2026-07-25 and **rejected**. It cuts the Fluorite 2 top-edge residual
  5938 → 1920 at −10 px and lands *under* the Helicon reference at every
  Azurite column — but the darkening-overlay map shows it starting to outline
  *interior* crystal contacts inside the Azurite subject (68k bright pixels
  darkened >1000 vs 24k shipped), the exact failure the 0.42 margin protects
  against. What shipped instead is the **rim-adjacency scoped relaxation**
  (`HYPERFOCAL_DESPILL_SPILL_LO_RIM` 0.30 within `HYPERFOCAL_DESPILL_RIM_RADIUS`
  2 cells of the backdrop reconstruction's near-black anchors): the last
  background cell before a silhouette carries the halo spike but reads
  spill ≈ 0.44 — inside the relaxed band, so it keeps its fit weight — while
  an interior contact never borders true backdrop and keeps the 0.42 edge.
  Measured: the full benefit at silhouettes (top edge −10 px 5938 → 2066,
  matching the global retune), Azurite acceptance columns unchanged, and all
  514 sampled extra-darkened bright pixels within 24 px of true-black
  background (darkened count 29k vs 24k shipped vs 68k global). Two failed
  levers, for the record: shrinking the guided radius r 8 → 4 gains only
  ~25% more (1537) and risks fit twitchiness elsewhere; weighting the
  aBar/bBar coefficient smoothing by the spill mask measured *worse* (2377),
  so the residual ~2k at −6/−10 is guided-filter smoothing itself, not
  weighting — accepted (reference leaves ~73–335 there; ours is a whisper at
  4× lift).
- **Per-pixel despill floor (2026-07-26).** The ~2k "accepted whisper" above
  was visible at normal brightness on Fluorite 2 (user report, crop of the
  calcite top edge). Root cause, measured from the grid dumps: the residual
  band lives in the last 1–2 grid cells before the silhouette, where mixed
  cells corrupt BOTH despill signals — spill-strength reads 0.25–0.39 (below
  even the relaxed rim edge, so the gate starves) and a cell straddling the
  edge carries a rim-inflated floor (4362 vs a 1990 glow at x=3880, so the
  l−floor bound blocks correction regardless of any gate knob). Apply-time
  knob turns cannot fix this: the best combination measured
  (`SPILL_LO_RIM` 0.20 + `CONTAM` 5/15) halved the band but ate the subject
  (−39% at 3–6 px inside the silhouette at x=3700) — rejected. What shipped
  instead: fusion retains per-PIXEL two-smallest and max luminance
  (`DespillInputs.perPixelFloor`/`perPixelMax`, all three engines, wgpu
  kernel parity inf dB), and `Despill.apply` subtracts straight to
  max(pixel floor, reconstructed backdrop) inside a rim-adjacent band.
  Gate lessons, each measured:
  - Every gate term multiplies (l − t), so a term at 0.97 leaves 3% of a
    bright glow ≈ 1800 counts of fresh halo. Terms must plateau at exactly 1
    inside the band (dim cap starts at 0.10 linear, above the brightest
    measured glow ~0.055; the upsampled adjacency is re-smoothstepped to a
    plateau).
  - The decisive subject/glow discriminator is **l ÷ per-pixel max**: a halo
    pixel renders far under its brightest frame (0.02 median in the band), a
    dim subject rim / bokeh disc / shadowed background renders at its
    brightest (0.86–0.97 at every wrongly-eaten site). Window 0.35/0.60.
    Winner-frame luminance was evaluated for the same duty and rejected —
    argmax picks defocused bokeh-rim false sharpness in the band, so a
    winner floor blocks the halo correction itself.
  - Pixel-path adjacency anchors need a spill-ish veto (0.25/0.40): a
    near-black cell with real signal is a dark subject body (spill
    0.15–0.31), not backdrop (0.30–0.45+); anchoring on it ran the pass
    across whole dark crystal faces. The veto cut sample-stack subject
    touches 94% (20638 → 1206 px) with the band fix intact.
  Landed state: Fluorite 2 band 100–500 (was 500–4600) at −10..−20, at/under
  the Helicon reference, monotonic; Azurite acceptance columns bit-identical;
  sample-stack metrics identical; Fluorite glint cores (>30k) untouched.
  Residual open point: dim (5–30k) defocus-spread of specular streaks within
  ~2 cells of a silhouette is statistically identical to glow and gets
  debloomed (~11k px on the Fluorite stack) — glint cores stay, the haze
  around them thins. Judged acceptable; revisit if a stack shows it as
  damage. CPU↔GPU cross-check on the real stack: default GPU fuse matches
  the CPU chain within a few counts at every probe point.
- **Black-point veil gate** (`HYPERFOCAL_BLACK_POINT_GATE_LO`/`_HI`, default
  0.02/0.06 over the max-channel *encoded* veil): anchor measurements are
  0.4–0.6% for genuine dark-backdrop veils (Azurite R263 G229 B0; Fluorite 2
  R0 G365 B410, /65535), vs **24.5%** on the white-marble sample-stack and
  **50%** on the synthetic plane scene — where an ungated subtraction crushes
  the sample-stack background to 0, halves its subject shadows, and drops the
  synth PSNR gate from 38.75 to 8.8 dB. The 40× separation is why the gate can
  be automatic and the pass needs no user control.

## Validate at FULL RESOLUTION. This is not optional.

A downscaled stack is not a valid proxy for these passes. Despill's grid is
8 px; at half resolution each cell covers 16 px of scene, so the near-rim band
that the whole argument is about (6–20 px of scene) becomes sub-grid-cell and
the correction cannot resolve it. Debloom's gate has the same problem from the
other end.

This inverted a conclusion **twice**:

1. On `~/Desktop/Azurite Downscaled` (canvas 4028×2602), PMax + despill left
   4146 at the equivalent of −10 px, and the finding was written up as "despill
   structurally cannot help PMax; the near-rim residue is one grid cell wide."
   At full resolution the same code produced **871** against Helicon's 864 — it
   lands *on* the reference. The entire conclusion was an artifact of the proxy.
2. The debloom near-black gate measured as a serious Azurite regression
   downscaled (13970 vs 8628 at −3). At full res it was a wash, and closer to
   Helicon than the shipped code at three of four columns.

Downscaled stacks are fine for a smoke test that the code runs, and for
*relative* comparisons within one resolution (gate A vs gate B on the same
canvas). They are not fine for any go/no-go. A full-res Azurite fuse is ~30-50 s
on the GPU; there is no excuse.

Related: benchmark numbers from a loaded machine inverted the GPU-vs-CPU
ordering too (see ROADMAP). Measure quiet, measure full-res, measure
like-for-like.

## The profile script

```python
import subprocess, numpy as np

def gray16(path):
    w, h = map(int, subprocess.run(["magick", "identify", "-format", "%w %h", path],
                                   capture_output=True, text=True).stdout.split())
    raw = subprocess.run(["magick", path, "-alpha", "off", "-colorspace", "gray",
                          "-depth", "16", "-endian", "LSB", "gray:-"],
                         capture_output=True).stdout
    return np.frombuffer(raw, dtype="<u2").reshape(h, w).astype(np.float64)

DISTS = [6, 10, 20, 30, 50, 80]      # px outside the edge (HALVE for a half-res canvas)
COLS  = [3350, 3410, 3470, 3530]     # Azurite full-res columns
HALO  = 90                           # fuse -> Helicon x offset

def profile(img, x, span=2, thresh=20000, ysearch=range(1200, 2300)):
    col = img[:, x - span:x + span + 1].mean(axis=1)
    ey = next((y for y in ysearch if col[y] >= thresh), None)
    if ey is None:
        return None, None
    return ey, [col[ey - d - span:ey - d + span + 1].mean() for d in DISTS]

for col in COLS:
    ey, v = profile(gray16("fused.tif"), col)
    print(f"x={col} edge_y={ey} " + "  ".join(f"{x:7.0f}" for x in v))
    # ...and against a Helicon re-export, if you have one:
    #   ey, v = profile(gray16("Helicon Azurite.tif"), col + HALO)
```

For the sample-stack metrics, load RGB instead (`-depth 16 rgb:-`, reshape
`(h, w, 3)`), take luminance as `0.2126R + 0.7152G + 0.0722B`, and read the two
fixed points in the table above.
