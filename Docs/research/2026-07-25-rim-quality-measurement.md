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
