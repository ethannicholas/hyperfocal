# PMax's debloom gate is dark-backdrop-only

Why PMax leaves a soft, haloed silhouette against a *bright* background, what
the near-black gate actually does, and why the obvious fix — removing that gate
— is wrong despite every sharpness number improving. Written after a
side-by-side against a commercial stacker on a model-train stack (bright blue
backdrop) turned up two distinct defects that looked like one.

Read before touching `PyramidFusion.nearBlackMasks`, the focus-gated coarse
selection, or `PyramidFusion.Options`. Companion to
`2026-07-25-rim-quality-measurement.md`, whose measurement discipline is what
kept this from being decided wrongly.

## Two defects, one appearance

A high-contrast subject against an out-of-focus background showed, in our PMax:

1. **Highlight bloom** — bright features (a white body stripe, white lettering)
   glowing into their surroundings, the surrounding colour washed out.
2. **A soft, haloed silhouette** — the subject's edge against the background
   smeared over many pixels where the reference render had a clean boundary.

These look like the same artifact and are not. Debloom (the focus gate) fixes
(1) and does nothing at all for (2).

## Why debloom misses the silhouette

`nearBlackMasks` multiplies the gate by a **near-black membership**:
`1 - smoothstep(lo, hi, lumMin0)`, with `lo = 0.15·scale`, `hi = 0.35·scale`,
`scale` = a high percentile of the per-cell min luminance. On the train stack
that is `lo = 0.127, hi = 0.296`.

Measured on that stack:

| region | near-black membership |
|---|---|
| whole frame | mean 0.074; **87.2% of pixels below 0.01** |
| background beside the soft silhouette | **0.0053** (its lumMin is 0.55) |
| the lettering debloom visibly fixed | 0.14 |

So the gate is off almost everywhere, and *exactly zero* where the silhouette
defect lives. **Debloom only ever engages on a dark backdrop.** That is not a
tuning accident — the membership is a deliberate restriction, and a bright
background is outside it by construction. The lettering improved because its
surroundings are dark enough to score 0.14; the silhouette could not.

## Rejected: removing the near-black mask

`HYPERFOCAL_PMAX_NEARBLACK_OFF=1` makes the silhouette crisp — visibly matching
the reference — and improves every sharpness measure available:

| stack | backdrop | gated | ungated |
|---|---|---|---|
| train | bright blue | −7.9% vs reference | **+16%** |
| bottlebrush | black | −1.3% | +2.7% |
| azurite | black | +44% | +55% |

Edge-anchored profiles (the method in the companion doc) stay **monotonic at
all four Azurite columns** — no trough, no moat — so it introduces no dark halo
and no over-subtraction. On that evidence it looks like a clear win.

**It is not.** Ungating dims the brightest content on every stack tested:

| stack | top 1% highlights |
|---|---|
| train | **−9.5%** |
| fluorite (white marble, inverted contrast) | −9.2% |
| azurite | −7.7% |

And it is indiscriminate. Splitting the train's top-1% highlights by local
focus: **sharp, in-focus highlights lose 8.49%, bloomed ones 8.84%** —
correlation between light removed and local focus is only **−0.138**. It is not
selectively removing bloom; it is removing highlights, and buying edge sharpness
with them. The near-black mask, crude as it is, is what prevents that.

**The measurement lesson, and it is the important part of this document:** a
sharpness metric *rewards* dimming highlights, because dimming a bloomed
neighbour raises local contrast. Every energy-based number said "ship it". Only
a photometric check — mean luminance of the brightest percentile, split by local
focus — showed the cost. Pair any debloom or rim change with that check; the
companion doc's edge profiles do not catch it either, because the loss is inside
the subject, not in the background tail.

## The actual design problem

The near-black membership answers two different questions with one threshold:

* *Is this a background region that could be bloomed into?*
* *Is this a genuinely bright in-focus feature we must not dim?*

Absolute luminance separates those two **only on a dark backdrop**, where
background is dark and features are bright. On a bright backdrop the first
question wants "yes" and luminance says "no", so the gate switches off precisely
where it is needed. Widening the threshold fixes the first question and breaks
the second — that is what the rejected experiment above measured.

So the fix belongs in **how the coarse selection decides**, not in the mask's
threshold. Focus is the natural discriminator (bloom is defocused by
definition), but note the −0.138 correlation: the existing two-track focus
select is not on its own selective enough to carry the decision once the
luminance restriction is lifted. Any candidate must be judged against both:

1. The silhouette against a **bright** backdrop becomes crisp.
2. Top-1% highlight luminance holds within ~1% of the gated result, on a dark
   backdrop, a bright backdrop, and the inverted-contrast (dark subject on white)
   case — all three, because they fail differently.
3. Azurite edge profiles stay monotonic (no trough, no moat).

## Status when this was written

PMax trails the commercial reference on nearly every stack where both tools
consume identical input pixels (contrast-normalized, worst case ≈ −13%), while
DMap is at parity on the same set. The stacks where we appear far ahead are all
raw, where the comparison also includes each tool's raw decode and so cannot be
attributed to fusion. Treat closing the PMax gap as open work; the per-stack
numbers live with the reference corpus, not here, because they will age.
