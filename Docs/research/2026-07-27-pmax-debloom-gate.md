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

## 2026-07-27, later: the discriminator, what shipped, and the criterion this
## doc was missing

A candidate discriminator was built and measured against the criteria above.
Most of it shipped; the headline case did not, for a reason the criteria as
first written could not see. Three results, in order of importance:

### The missing criterion: the source-frame floor

Criterion 2 (top-1% highlight luminance) is necessary but not sufficient. The
keep-darkest track B, once admitted to a bright backdrop, renders the band
beside a dark silhouette **below the darkest source frame's own rendition** —
on the train stack's blue backdrop, 66% of the most-affected pixels fell below
the per-pixel minimum over registered source frames (0.478 vs a frame floor of
0.507), and on a dark-specimens-on-white stack, 73% (0.759 vs 0.785). That is
darkness no frame contains — a painted dark halo. The commercial reference is
at 0% on both stacks: crisp *without* undershooting. The top-1% check misses
this entirely because the damage sits at backdrop luminance (~0.5), nowhere
near the top percentile; the edge profiles read it as *improvement* (steeper
falloff = "crisper"). **Add to the criteria: in never-focused background, the
fused result must not drop below the per-pixel min over registered source
frames.** Check it with `debug-register` on 2-3 frames spanning the sweep.
This is the same lesson as the top-1% check, one octave down: energy and
profile metrics reward manufactured contrast wherever it comes from.

By that standard the "ungated fixes the silhouette" result earlier in this doc
was partly the same trap. Ungated debloom does fix the smear — and pays for a
chunk of the crispness with sub-floor darkening that the Azurite profiles
(black backdrop, nothing below to undershoot *to*) could not show.

### The train silhouette is not the additive case

The doc above implicitly modeled the bright-backdrop defect as bright features
blooming outward (additive). Measured per pixel (is `lumMin` or `lumMax` the
one matching the local clean level?), the train's silhouette band is
**subtractive-dominated** — the roofline is a dark subject on a bright
backdrop, the same contamination sign as the inverted-contrast marble case,
just at different absolute levels. Keep-darkest there keeps the *most*
contaminated frame plus overshoot; keep-brightest was already rejected (the
other extreme). Track A cannot help either: measured with track B disabled,
the profiles revert exactly to shipped — the band cells have no fine focus in
any frame, so the A/C choice never engages there. **No merge built from
per-cell extreme order statistics fixes a subtractive band without painting a
halo.** The fix that remains open: a track B that keeps the frame *closest to
the local clean background level* — which needs a local clean-field estimate
(the luminance analog of despill's backdrop reconstruction), not just per-pixel
min/max.

### What shipped: the membership, sign-gated

`debloomMasks` (was `nearBlackMasks`) now unions two background proofs — the
near-black membership, unchanged, and an **open-background membership**: pixels
in a connected smooth field that (a) reaches the frame border without crossing
sharp structure (small-radius close of the sharp mask + border-connected
components — enclosure is what protects bright feature interiors, half of
whose top-1% pixels have no fine detail in any frame), (b) never comes into
focus (per-component median of focus max/min across frames — an in-focus
background's energy moves ~5000:1 with the sweep, a never-focused backdrop's
~2:1, and absolute energy cannot separate them because a white-marble
substrate's real texture overlaps a blue backdrop's noise floor), and (c) is
**additively contaminated** where contaminated at all (per-component vote +
per-pixel veto against the component's far-field level, from the full-res
per-pixel min/max luminance planes all three engines now accumulate).

Clause (c) is what the frame-floor criterion forces: it correctly holds the
train and the white-background specimens at shipped behavior (their bands are
subtractive), while opening additive cases. Measured effect on the corpus: one
stack with a defocused-foliage background improved — its background tiles had
been rendering **2-4x more focus energy than any registered source frame
carries** (max-of-N noise amplification, the same signature this corpus uses
to discount the commercial render's sharpened backgrounds), and now sit inside
the source envelope; top-1% moved −0.6%. Every other corpus stack is
bit-identical or within engine noise; Azurite acceptance profiles unchanged
and monotonic; probe and wgpu parity green.

## 2026-07-27, still later: the clean-field track B, and where its validity ends

The follow-up landed the same day. Track B in open-background cells is now
**sign-aware**: the streaming select keeps BOTH unfocused extremes (darkest
and brightest band per cell), and the merge picks whichever luminance lands
closer to a **clean-field plane** — push-pull reconstructed from the open
field's uncontaminated pixels (per-pixel min/max agreeing), the luminance
analog of despill's backdrop reconstruction. The choice is scoped to
open-background cells; near-black-only cells keep plain darkest, so every
dark-backdrop behavior is verbatim.

Measured on the bright-blue-backdrop stack: the silhouette profile moves
about half way from shipped to the reference (matching it at 6 px), with
**zero** source-frame-floor violations and top-1% at −0.03% — crisper *and*
photometrically honest, unlike keep-darkest. Ground truth vindicates the
reference here: its profile matches the subject-sharp source frame's own
transition almost exactly, tail included.

Three boundaries found and measured, each now enforced or documented:

- **Per-cell selection cannot reproduce the sharp frame's full transition.**
  The remaining profile gap (10–30 px) is the sharp frame's genuine edge
  tail, which a smooth clean field cannot represent and per-cell/per-level
  independent choices cannot render consistently — a peak-focus variant
  reached it only by violating the frame floor again (19.9%). The full fix
  is DMap-style regional frame consistency; that is the remaining open item.
- **The mechanism deadens textured defocused backgrounds.** On a stack with
  a lively out-of-focus garden, nearest-to-clean picked the flattest
  rendition per cell and visibly flattened mottle the scene really has
  (background tiles at 0.3–0.7× the liveliest source frame; the reference
  keeps the mottle, and soft petal shading was flattened too). Hence the
  **flatness gate**: a component opens only if its clean anchors, gradient
  removed, sit at their noise floor (σ < 0.0035; measured flat backdrops
  0.001–0.003 vs textured 0.005–0.08). This deliberately scopes the whole
  open-background mechanism to flat backdrops — exactly where the clean
  field is a faithful model — and returns every textured-background stack
  to shipped behavior bit-for-bit.
- **Thresholds near a population must clear it on every engine.** A first
  flatness cut of 0.0045 sat a hair under one stack's 0.0046 — which closed
  on the CPU's planes and opened on the GPU's slightly different ones:
  engine-dependent output. The cut lives at the geometric middle of the
  measured gap, and `HYPERFOCAL_PMAX_BG_DEBUG=1` prints each component's
  flatness so the margin can be re-checked when new stacks join the corpus.

## Status when this was written

PMax trails the commercial reference on nearly every stack where both tools
consume identical input pixels (contrast-normalized, worst case ≈ −13%), while
DMap is at parity on the same set. The stacks where we appear far ahead are all
raw, where the comparison also includes each tool's raw decode and so cannot be
attributed to fusion. Treat closing the PMax gap as open work; the per-stack
numbers live with the reference corpus, not here, because they will age.

(2026-07-27, later: the worst-case stack was diagnosed — mostly the
reference's output sharpening, plus a narrow weak-speckle selection loss on
our side; see ROADMAP and the corpus README. The fusion-gain-vs-registered-
source-frames test used there is the general instrument for splitting
"their sharpening" from "our loss": a fused render owing its energy to
sharpening *exceeds* the best registered source frame broadly, which honest
fusion cannot.)
