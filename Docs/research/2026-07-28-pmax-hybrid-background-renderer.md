# PMax hybrid background renderer — design note

How PMax should render regions that never come into focus: from a regional
frame decision at EVERY pyramid level, the way DMap renders everything, while
per-coefficient selection keeps the subject. Design only — nothing here is
implemented, and nothing should be until the acceptance criteria at the end
are wired into the measurement first.

Read `2026-07-27-pmax-debloom-gate.md` before this; its final section is the
measured post-mortem this note starts from. The ROADMAP item "Close the PMax
gap" carries the priority context.

## One problem wearing four costumes

Four open quality items, previously tracked separately, are the same defect —
per-coefficient, per-level *independent* max selection in regions where no
frame has focus:

1. **The silhouette edge tail (10–30 px).** The clean-field track B closes
   half the bright-backdrop silhouette gap; the rest is the sharp frame's own
   edge tail, which per-cell/per-level independent choices cannot render
   consistently. A peak-focus variant reached it only by violating the
   source-frame floor (19.9%).
2. **Textured defocused backgrounds are excluded on purpose.** The clean-field
   merge deadens real bokeh mottle (0.3–0.7× the liveliest source frame), so
   the flatness gate scopes the whole open-background mechanism to flat
   backdrops. The gate is a confession: the clean field is the wrong renderer
   for texture.
3. **Background noise amplification.** Plain max-of-N renders defocused
   backgrounds at 2–4× the focus energy of every registered source frame —
   energy the sources don't contain, the same signature this project uses to
   discount the commercial reference's sharpened backgrounds.
4. **(New, 2026-07-28, and not even PMax.)** DMap has the mirror-image
   failure: where no frame ever focuses, its depth plane is noise, and
   blending 2–3 frames of decorrelated bokeh mottle *averages real texture
   away* — measured 0.36× the liveliest registered source frame on a
   defocused-garden stack, against the commercial render's honest 0.95×.
   Parameter sweeps (noise floor, peak concentration, both regularizer radii,
   blend radius, despill) all move it ≤1 point: it is intrinsic to
   blend-across-noisy-depth, not tuning.

Items 1–3 are PMax selecting *incoherently* across levels and cells; item 4 is
DMap blending *incoherently* across frames. The shared fix is **regional
commitment**: in never-focused regions, decide per region which frame renders
it, and render that frame faithfully. A defocused background has no "right"
sharpness to find — every frame's rendition is equally valid photometrically —
so the only wrong answers are the ones that match no frame at all, which is
precisely what both incoherent mechanisms produce.

## What the prototype settled (keep) and refuted (do not retry)

The coarse-only prototype (debloom-gate doc, final section) was built end to
end on the CPU and measured. Its parts are load-bearing for this design:

**Keep — verified working:**

- **The regularized frame map.** Per-cell argmax of the box-pooled level-0
  focus (with frame identity), votes baseline-subtracted so noise-floor cells
  contribute exactly nothing, then nearest-confident-cell propagation bounded
  to ~48 px. Confidence must come from ALL cells — the adjacent subject edge
  is where it lives (background-only voting covered 6% of the band) — while
  *assignment* stays background-only. Verified: assigns the subject-sharp
  frame across the whole band beside the bright-backdrop silhouette.
- **The selective second pass.** Re-decode only the frames the map assigns
  significant coverage to (at most four in practice), rebuild their pyramids
  in the existing workspace, and materialize what substitution needs. The
  decode closure is still available after streaming; cost is 1–4 extra frame
  decodes.

**Do not retry — each failed measurably:**

- Requiring a window MEAN to beat noise (assigns nothing anywhere).
- Windowed/weighted MEDIAN voting (mixes the subject's own depth gradient
  into the verdict; interior cells outvote the silhouette edge).
- **Coarse-only governance.** Substituting the map frame's coarse bands while
  fine levels stay max-of-N mixes two inconsistent selections in one region:
  no decisive silhouette gain, and lively backgrounds got WORSE than plain
  selection (2.8× the liveliest source frame vs 2.1×). Governance is
  all-levels-or-nothing.
- (From the earlier rounds:) any merge built from per-cell extreme order
  statistics for a subtractive band — keep-darkest, keep-brightest, and
  peak-focus each paint a halo the source-frame floor catches.

## The design

### Membership: where governance applies

The existing open-background membership (`debloomMasks`' union arm) is the
right region finder: connected smooth fields that reach the frame border
without crossing sharp structure, and never come into focus across the sweep.
Enclosure already protects bright feature interiors; the never-focusing test
(per-component focus max/min ratio) already separates a true backdrop from an
in-focus substrate.

Two of its current restrictions exist only to protect the clean-field merge,
and should retire *with* it inside governed regions:

- **The flatness gate** (σ < 0.0035) exists because nearest-to-clean deadens
  texture. A frame-governed region renders one frame's actual texture, which
  is honest by construction — so textured backdrops (bokeh gardens, mottled
  defocus) can open. This is the gate's planned retirement path, not a
  loosening: the gate stays until governance replaces the clean-field track,
  then both go together.
- **The additive-only clause** (sign vote + veto) exists because keep-darkest
  painted sub-floor halos. Governance doesn't keep an extreme — it keeps a
  frame — so subtractive bands (the bright-backdrop silhouette, dark subjects
  on white) become eligible. This is exactly the remaining-silhouette fix.
  The frame-floor criterion still has to prove it per stack.

The near-black-only arm and everything outside the membership keep shipped
behavior verbatim, as the clean-field change already demonstrated how to do.

### The frame decision: engine-internal, not the app's DMap peer

Two candidate depth sources were on the table:

- **A. The DMap peer.** The macOS app already fuses DMap in the background
  for every PMax-primary stack (depth for retouch), and hands PMax the warped
  frame cache from that fuse. Tempting: a full regularized depth map, already
  paid for — in the app.
- **B. The prototype's frame map**, built from data the streaming pass
  already has.

**B is the recommendation, and app/CLI parity is the reason.** The fused
output must be a function of the engine's inputs, identically on every
surface — that is the shared-defaults invariant, and it was violated once
already (debloom shipped on in the app, off in the CLI, and every CLI
measurement described a configuration no user saw). If PMax consulted the
app's DMap peer, the CLI would need a full DMap fuse inside every PMax fuse
to match — roughly doubling CLI PMax cost — or the two surfaces would render
different pixels, which is the forbidden outcome. The frame map needs no
second fusion, no new inputs, and produces the identical decision everywhere
the engine runs.

Two further points against A, found while diagnosing the DMap mottle problem:
the peer's depth is *noise* exactly where governance needs an answer (never-
focused regions — that is item 4 above), so consulting it would import the
scatter this design exists to remove; and the peer is regularized toward
DMap's rendering needs (per-pixel blending), not toward regional commitment.
The frame map's confidence-propagation IS the commitment mechanism.

What A still offers later: if the map's regional decisions and the DMap
peer's depth disagree badly somewhere, that disagreement is a diagnostic —
worth logging in the app, never worth consuming in the render.

### Rendering: govern every level, blend at region edges

Inside a governed region, ALL levels — fine bands, gated coarse bands, and
the base Gaussian — come from the map frame's pyramid, materialized in the
selective second pass. That is the all-or-nothing lesson: the background is
rendered the way DMap renders everything, from one frame per region, while
the subject keeps PMax's per-coefficient contest (overlapping structures are
the reason PMax exists).

Blending, three seams to handle:

1. **Membership boundary (subject ↔ background).** The membership weight is
   already a smooth field; lerp per level between the max-of-N coefficients
   and the governed coefficients by that weight, the same scoping pattern the
   clean-field merge uses today.
2. **Frame-map transitions (background region ↔ background region).** Where
   the map changes frame assignment, blend the two frames' coefficients over
   a feather measured in image space per level (wider at fine levels in cell
   units). DMap's render blend is the model; a hard cut would print the seam.
3. **The stack's photometric drift.** Adjacent assigned frames differ
   slightly in exposure; the existing per-frame gain normalization applies to
   the re-decoded frames exactly as the streaming pass applied it.

### Options and parity plumbing

One new field inside `PyramidFusion.Options` — never a parameter riding
alongside it — with off-as-a-value:

- `backgroundGovernanceRadius: Int = 0` (propagation bound in cells; `0` =
  off, shipped behavior; the prototype's working value maps to ~48 px). One
  value is both the off switch and the reach dial, matching the debloom
  slider pattern, so the app's control and the CLI's `@Option` both derive
  from `PyramidFusion.Options().backgroundGovernanceRadius` and cannot
  diverge.

Ship-on is the goal, but only after the criteria below pass on the full
corpus; until then the default stays 0 and the flatness-gated clean field
keeps shipping.

Both UIs gain the control in the same change (SwiftUI + QML + bridge + ten
languages), per the dual-UI invariant. `retouch-probe` gains a defaults
assertion the day the field exists.

### Engine parity

The prototype is CPU-only. The production version must land on CPU, Metal,
and wgpu with ≥90 dB agreement, or run the second pass CPU-side for all
engines (the re-decode + substitution touches 1–4 frames — measure whether
CPU-side substitution keeps GPU fuse wins before porting kernels). The
threshold lesson from the flatness gate applies to the map too: any cut
near a measured population must clear it on every engine (the 0.0045 cut
that closed on CPU planes and opened on GPU planes cost a day).

### Interactions

- **Retouch depth.** PMax strokes currently leave the depth plane untouched
  because PMax has no depth. Governed regions give it one (the map's frame
  index); folding that into the depth/retouch story is optional follow-up,
  not part of this change.
- **DMap's mottle flattening (item 4).** The same regional-commitment
  machinery, applied at DMap's render stage (commit no-confidence regions to
  a single frame instead of blending noisy depth), is the likely fix. Design
  both against the same acceptance criteria; land separately.
- **Despill/black point** run downstream of fusion and are unaffected.

## Acceptance criteria — now six

**Wired (2026-07-28, later):** criteria 1–5 are now one runnable harness
beside the private corpus (`pmax-acceptance.py` — see the corpus README for
the baseline table and the instrument calibration notes). At current HEAD the
baseline reads: C1–C4 PASS, C5 FAIL on both textured-background stacks —
quantifying the open item this design exists to fix (fabrication up to 2.8×
the best registered frame on defocused foliage; fabrication *and* deadening
on a dark garden via the near-black track). A candidate flips C5 to PASS
without moving C1–C4 or C6. Two instrument findings worth carrying: the
harness's self-anchored silhouette profile shows shipped already *matching
the subject-sharp frame's transition shape*, with the commercial reference
overshooting it — so criterion 1's remaining value is guarding against
regression and manufactured edges, and the 10–30 px "remaining gap" of the
fixed-anchor instrument should be re-examined under both instruments before
any silhouette work is scoped from it.

The four from the debloom doc, plus one the mottle measurements force, plus
parity. A candidate must clear ALL of them; each exists because some metric
approved a defect:

1. **Bright-backdrop silhouette:** the edge profile approaches the
   subject-sharp source frame's own transition, tail included (the reference
   matches that frame almost exactly; the clean-field merge already matches
   to 6 px — the criterion is the 10–30 px remainder).
2. **Top-1% highlight luminance** within ~1% of shipped, on dark, bright,
   and inverted-contrast stacks — all three, they fail differently.
3. **Edge-anchored profiles stay monotonic** on the dark-backdrop acceptance
   stack (no trough, no moat).
4. **Source-frame floor:** in never-focused background, no pixel below the
   per-pixel min over registered source frames (`debug-register` 2–3 frames
   spanning the sweep; erode warp alpha before measuring).
5. **Source-envelope on texture (new):** governed background tiles stay
   within the registered-source envelope on BOTH sides — no tile above ~1.1×
   the best registered frame (no fabrication) and none below ~0.7× the
   liveliest frame (no deadening). This is what the flatness gate enforces
   today by exclusion; governance must earn the gate's retirement by passing
   it inclusively, on the lively-garden stack that motivated it.
6. **Engine parity ≥90 dB** across CPU/Metal/wgpu, and bit-identical output
   on every corpus stack whose membership doesn't open (the clean-field
   change demonstrated this is achievable and it is the regression fence).

Measurement discipline per the corpus README: compare.py for renders, both
registration directions, absolute band values against registered frames (the
edge-anchored profiles under-report exactly the fix being attempted here —
the darkest base depresses the far-field anchor), and full-resolution
validation.

## Cost estimate

Streaming pass: unchanged (the map's inputs — box-pooled level-0 focus with
frame identity, per-component stats — are already accumulated for the
debloom membership). Second pass: 1–4 frame decodes + pyramid rebuilds in
the existing workspace, only when the membership opens and the map assigns
coverage; stacks with no open background pay nothing. That is the same
cost class as the despill second pass the pipeline already tolerates.

## 2026-07-28, later: implemented (env-gated, default off) — what the build
## taught, and what still stands between the candidate and C5

The renderer above is now in the engine
(`PyramidFusion.governBackground`), CPU-only, behind
`Options.backgroundGovernanceRadius` (default 0 = shipped behavior;
`HYPERFOCAL_PMAX_GOV_RADIUS` is the experimental surface until the ship-on
decision, so the dual-UI invariant is not tripped early). Default-off is
bit-identical — verified by A/B against the pre-change build on the CPU
engine, and `retouch-probe` asserts the default stays 0 until the UI
surface lands. It landed after (and was re-based onto) the smoothed
selection + Burt expand + source-envelope work, which independently removed
about half the C5 fabrication this design was scoped against.

With the prototype's radius (6 cells ≈ 48 px), the acceptance harness
reads: **C1–C4 exactly unmoved** (C2 within 0.01%, C4 within 0.01 pp) and
**C5 moved substantially on both stacks but not flipped** — the
defocused-foliage stack's fabrication 25 → 11 high tiles (with 12 new low),
the dark-garden stack's deadening 27 → 6 low (with 8 new high). Stacks the
scope gate skips change only by CPU↔GPU engine variance (~0.3% of pixels).

The design survived contact mostly intact; four of its choices had to be
*corrected by measurement*, and each correction is load-bearing:

- **Commitment is per block (64 px), not per cell.** Per-cell argmax — even
  mode-regularized — puts a seam every few cells; with an 8–24 px feather
  against ~100 px acceptance tiles, most of every tile was transition, and
  a half-weight blend of decorrelated fields carries HALF their energy
  (energy is quadratic in blend weight). Regions must be much larger than
  the feather, and the feather much larger than a cell.
- **The frame decision is a measured energy argmax, not vote inference.**
  A per-block × per-frame energy table accumulated during streaming (a few
  MB even at 45 MP × 80 frames) decides each block over ALL frames;
  remapping to the ≤ 8 re-decoded dominants is a second measured argmax,
  never a frame-index guess (index-distance remap committed regions to
  frames that are dull where they are: 0.6–0.8× the liveliest rendition).
  Choice sums run over membership cells only — subject cells otherwise hand
  a boundary block to the subject-sharp frame, whose background is
  maximally defocused exactly there (measured 0.19×).
- **The render is a convex composite in image space, not band-coefficient
  substitution.** Per-level coefficient blending failed twice: a
  level-pixel-constant feather de-synchronizes transition widths across
  levels (the coarse-only prototype's incoherent mix, reproduced at every
  seam), and band-space mixing of slightly misaligned content rings below
  both sources (2.25% of a flat backdrop under the C4 floor, in clean
  64 px rectangles). At weight 1 the image composite IS full-pyramid
  substitution (the collapse of a frame's pyramid is the frame); in
  feathers it is bounded by its sources, so C2/C4 hold by construction.
- **Scope is the flatness gate's complement, gated at stack level on the
  clean-field geometry.** Governing everything the membership reaches
  repainted healthy flat backdrops wholesale (25–81% of pixels on stacks
  with no open defect, block-scale luminance mosaics under the C4 floor,
  a C1 overshoot from seam gradients). One flatness measurement now serves
  both mechanisms: the clean field keeps components below 0.0035,
  governance takes components above 0.006 on stacks whose *clean-geometry*
  components prove texture (the governance-widened geometry merges
  never-focusing painted surfaces into the open field and cannot be
  trusted for this judgment); the band between the cuts ships unchanged.

Additions to the do-not-retry list, all measured this session: a raw-vote
confidence cut relative to p99 (landed below the vote median — half of
every backdrop "confident" by noise); a pixel never-focuses cut of 50 (the
gap between bokeh ≤ 30 and focusing ≥ 100 exists, but a hairy subject body
reads 20–50 and dissolves); absolute energy floors anywhere near dark
texture (a dark garden's real bokeh sits under every global floor — its
self-votes must survive); per-cell mode filtering as a regularizer (the
weights never saturate); and letting flat blocks commit (their argmax is
noise and the composite paints exposure mosaics).

**What still stands between the candidate and a C5 flip**, mapped per
tile: (a) partial-weight tiles at governance boundaries deaden by the
quadratic blend rule — the instrument sees any soft edge as a low; (b)
the dark-garden stack's remaining highs are seam tiles around a
misregistered frame (the frame-0 scale outlier the corpus README
documents) plus border tiles where the harness reference is still
coverage-thin after the coverage-aware fix; (c) the silhouette-band
improvement the prototype demonstrated is currently forfeited by the
stack gate on flat-backdrop stacks — deliberately, since C1 measures
shipped as already matching the sharp frame's shape. The C5 instrument
itself gained a calibration fix this session (per-frame tile means over
covered pixels only, 60% floor — zero-filled means depressed border
references and let genuinely-focusing sub-content masquerade as
never-focused); its baseline table moved accordingly.

One more instrument lesson, for whoever measures next: with the radius env
set the whole fuse runs CPU-side, and the saved snapshots are GPU renders —
on the old engine that confound alone produced a +2.25% top-1% "regression"
that was really CPU-shipped vs GPU-shipped. Judge candidates against a
same-engine baseline (the smoothed-selection ports have since brought the
engines close enough that the residual is ~0.3% of pixels).

## 2026-07-28, latest: manual review verdict — the radius-6 candidate FAILS
## by eye, and the criteria missed all four reasons

Side-by-side review of defaults vs the radius-6 candidate on the full
corpus found the candidate roughly strictly worse where it engages, despite
C1–C4 unmoved and C5 improved by tile count. Four observations, each a
criterion gap as much as a mechanism defect:

- **Backgrounds brighten well above the reference** (defocused-foliage and
  specimen stacks). Governed regions composite a single frame's FULL
  rendition, low frequencies included; shipped PMax builds background low
  frequencies from the darkest-base/debloom machinery, and replacing that
  lifts the whole field. No criterion watches background luminance LEVEL —
  C2 only bounds the top 1%. The all-levels-or-nothing lesson is about
  detail coherence; the BASE must keep shipped photometry (govern texture
  over the shipped low frequencies, not the image wholesale).
- **Blur patches on the subject and smears extending off petal edges.**
  The governance-widened subject test plus the opening melt thin subject
  structure (defocused petal edges) into the membership, and blocks there
  commit to background-lively frames that render the subject content
  blurred. The "a thin structure losing its exclusion is approximately
  safe" assumption is refuted by eye — the subject mask must stay
  conservative, full stop.
- **Sharp sub-content replaced by blur.** The never-focuses test is a
  component MEDIAN; regions that mostly defocus but contain genuinely
  focusing sub-content pass it, and commitment erases real sharpness. C5
  cannot see this — its filter drops exactly those tiles. Eligibility
  needs a per-cell focusing veto, not just a component-level one.
- **Visible background detail loss beyond what C5 flags.** The 0.7× floor
  over ~130 px tile means is far more lenient than the eye; the committed
  frame being "the liveliest available" at block scale does not survive
  sub-block inspection.

Verdict: the machinery (streaming block-energy table, measured block
commitment, image-space compositing, flatness-complement scoping) stands;
the current calibration does not. It stays default-off. The next attempt
should (a) govern fine texture only, compositing over shipped low
frequencies; (b) drop the subject-mask widening entirely; (c) add a
per-cell focusing veto inside governed components; and the harness needs a
background-luminance-level criterion plus a sub-tile blur instrument
before any candidate is trusted again — the eye caught four defects six
criteria approved.
