# Focus-stacking algorithm research — 2026-07-12

Two adversarially-verified deep-research passes run before starting the
Helicon-parity depth/render work (ROADMAP items 3a/3b). Method: 5 parallel
search angles per pass; top sources fetched; falsifiable claims extracted;
each surviving claim verified by a 3-vote adversarial panel (2/3 refutes
kill a claim). Raw workflow outputs are archived alongside this file
(`2026-07-12-focus-stacking-pass?-*.json`) — they include per-claim votes
and the full source table.

**Reading order:** the synthesis below, then pass 2 (product behavior —
the design-critical half), then pass 1 (academic). Refuted-claims sections
matter: they are things that *sound* plausible and were specifically shot
down.

## Synthesis → pipeline mapping (written 2026-07-12)

| Pipeline stage | Verdict from evidence |
| --- | --- |
| Focus measure (smoothed \|Laplacian\|) | Best family in clean conditions (Pertuz benchmark); WORST for noise; degrades >30% saturation (speculars). Window size is the dominant lever on low texture: quality 1.00→0.26 from 7×7→3×3. Our σ=3 is tiny vs Zerene's documented radii (up to 1/100–1/200 of width, scaled to blur); too-small radius is a documented cause of "hard-edged halos and blotches in low-contrast areas" — our observed artifact class. Candidates: Ring Difference Filter (TIP 2019, code public), multiscale dilated Laplacian (IJCV 2026, single-source), variance/Tenengrad as noise-robust complementary gates. |
| Confidence gating (noise floor × peak concentration) | Structure validated: Zerene's Contrast Threshold is a percentile confidence mask marking "can't tell" regions where smoothness overrides measurements; variational DfF (Moeller 2015) treats weak data terms as soft weights the regularizer overrides. Soft weighting > binary masking. |
| Fill / regularization (jump-flood + basin refinement) | Best-supported upgrade: guided filtering of the depth map with the AIF image (or focus-volume correlation) as guide (Ali PR 2021, CVIU 2022) — subsumes fill geometry; beware plain GIF's own halo risk (use adaptive-weighted variants). Stronger/costlier: aggregate the cost volume BEFORE argmax (RDF aggregation; separable 3D-WLS, Information Sciences 2019 — tridiagonal 1-D solves, GPU-plausible at grid res). REFUTED: "joint estimation markedly beats compute-then-smooth" — upgrade stages, don't restructure. |
| Render (hard argmax + tent blend) | Both vendors converged on exactly this: hard selection + small blend band (Zerene smoothing = estimation/2; Helicon B radius 8 / smoothing 4). Global energy-weighted averaging (Helicon A) documented to sacrifice sharpness — use energy weighting only inside low-confidence regions if at all. Pyramid (PMax/Method C) reserved for overlap regions; amplifies noise/contrast in both implementations. |
| PMax path | Noise mechanism documented: finest pyramid scale can't distinguish detail from noise; Zerene ships default-on "grit suppression" (suppress/soft-select finest scale). Direct cheap improvement for our PyramidFusion. |
| Retouch workflow | Vendor answer of record to the fundamental limit (correct pixels exist in NO frame at occluding discontinuities): DMap base retouched from PMax source — exactly our shipped retouch design. Automatable someday: flagged-region pyramid substitution. |
| Regression metrics | NO surviving claims in either pass (Q_AB/F, MI, SSIM-variants, Lytro/MFI-WHU/MFFW; Core ML-portable networks). Open — needs a dedicated pass if ever wanted. PSNR vs synthetic truth remains the gate. |

## Pass 2 — product behavior, halos, rendering (design-critical)

### Question

```
Focus stacking rendering/blending strategies and halo artifacts — the practitioner and product-behavior half of a research effort for a macro focus-stacking tool (the academic focus-measure and depth-regularization half is already done). Dig specifically into:

1. Halo / edge-bleed / "ghosting" artifacts at depth discontinuities in focus stacking: their optical cause (defocused foreground spill), and every documented mitigation — in Zerene Stacker's documentation and forums (PMax vs DMap: how each behaves at discontinuities, what the "contrast threshold" and "estimation radius"/"smoothing radius" DMap parameters actually do per their docs), Helicon Focus documentation (methods A weighted-average / B depth-map / C pyramid: exactly how each is described to behave, what the "radius" and "smoothing" parameters control, which method their docs recommend for which scenes and why), and practitioner sources (photomacrography.net, extreme-macro.co.uk, Zerene forums, srussenschuck.com's focus stacking artifacts pages).
2. Rendering from a depth map: evidence and practitioner experience on hard per-pixel frame selection vs blending several frames (weighted average within a depth window), contrast/energy-weighted blending, and hybrid schemes that use a Laplacian pyramid fusion constrained or guided by a depth map. Noise amplification behavior of pyramid max-selection (documented for Zerene PMax: increases noise/contrast) vs averaging methods.
3. Multi-focus image fusion quality metrics and benchmarks: Q_AB/F (Xydeas-Petrovic), mutual information, SSIM-based fusion metrics, the "Lytro" multi-focus dataset and MFI-WHU / MFFW benchmarks — definitions, what they measure, and whether any transfer to regression-testing a photographic tool with synthetic ground truth.
4. Deep multi-focus fusion / depth-from-focus models 2020+ that could practically run on Apple Silicon via Core ML (small U-Nets, boundary-aware fusion nets, GRU refiners over classical focus volumes): names, sizes, licenses, and any ports.

Prioritize primary product documentation (zerenesystems.com docs/kb, heliconsoft.com docs), practitioner forums, and for metrics/DL the primary papers. Output: concrete guidance for (a) whether to render by hard selection + small tent blend vs energy-weighted blend within a depth neighborhood, (b) what halo mitigations to implement at render time, (c) which quality metrics to add to our synthetic regression suite.
```

### Summary

Primary vendor documentation from Zerene and Helicon converges on the same rendering architecture: a depth-map method that does hard per-pixel frame selection softened by an explicit blend band (Zerene DMap's Smoothing Radius = half the Estimation Radius; Helicon Method B's Smoothing parameter), with a pyramid max-selection method (PMax / Method C) as the documented fallback for overlapping structures — at the documented cost of amplified noise, contrast, and color/glare shifts. Halos at depth discontinuities have a fundamental optical cause both vendors acknowledge: where defocused foreground occludes background, the desired pixel values exist in no source frame, so no per-pixel selection scheme can fully fix them; documented mitigations are (1) scale-matched focus-measure radius (too small → hard-edged halos and blotches, too large → broad loss-of-detail halos), (2) a contrast/confidence threshold that marks 'can't tell' regions where smoothness regularization overrides unreliable focus measurements, (3) the smoothing/blend band itself, (4) spatial threshold masks, and (5) hybrid retouching of a DMap base from a PMax source. For our tool this supports rendering guidance (a): hard argmax selection plus a small tent/soft blend within a depth neighborhood — mirroring both products — with an energy-weighted (Method-A-style) or pyramid path reserved for low-confidence and overlap regions; and (b): implement confidence gating with depth smoothness in flagged regions, radius scaled to blur, and optional per-region masks. Note that the metrics/deep-learning half of the question (Q_AB/F, MI, SSIM fusion metrics, Lytro/MFI-WHU/MFFW, Core ML-portable models) produced no surviving verified claims, so recommendation (c) cannot be grounded in this evidence set and remains open.

### Verified findings

#### Pass 2-F0: high confidence (3-0 unanimous on all three merged claims (7, 17, 14))

Optical cause and fundamental limit: halos at depth discontinuities are partly unfixable by any per-pixel selection scheme because the desired pixel values do not exist in any source frame — where a defocused foreground occludes background, no input image contains the background in focus up to the foreground edge. Both Zerene methods (PMax and DMap) fail specifically on isolated foreground features when the background behind them contains crisp high-contrast detail (foreground appears partially transparent with background bleeding through), and halos manifest most visibly as broad dark halos around bright subject features silhouetted against dark, low-detail blurry backgrounds.

**Evidence:** Zerene tutorial003: "in many stacks, the pixel values you want don't appear in any input file" — DMap cannot recover a focused background leaf up to the edge of a foreground petal; "There's no way around this problem using DMap or any other software that relies on just picking out the sharp bits." Retouching tutorial: "Both methods often have trouble with isolated foreground features, particularly where the background behind them also contains crisp high contrast details" (aperture "looks around" foreground structures, making them appear partially transparent). Retouching002 transcript: "broad dark halos that appear around bright features of the subject where it contrasts against dark background," worst where background lacks detail (dark-halo manifestation attributed to PMax; low-detail worsening documented for DMap's threshold stage). Corroborated by Helicon forum (lens/physics problem, not software-fixable) and Stanford focal-stack compositing paper.

**Sources:**
- http://zerenesystems.com/cms/stacker/docs/tutorials/tutorial003
- http://zerenesystems.com/stacker/docs/RetouchingTutorial/RetouchingTutorialTranscript.htm
- https://zerenesystems.com/cms/stacker/docs/videotutorials/retouching002/transcript

#### Pass 2-F1: high confidence (3-0 unanimous on all merged claims (0, 1, 9, 13, 15))

Zerene PMax vs DMap tradeoff (merged): PMax (pyramid max-selection) avoids the loss-of-detail halos typical of depth-map programs, gives less halo/edge-bleed at discontinuities, and is remarkably good at overlapping structures (crossing hairs/bristles) — effectively combining color from the focused-foreground frame with luminance from the background frame — but inherently increases noise (output noisier than ANY input frame) and contrast and can shift colors. DMap preserves original smoothness, colors, and contrast better but is worse at finding/preserving fine detail and shows characteristic artifacts at thin foreground features. Zerene frames them as complementary, not one universally better.

**Evidence:** howtouseit: PMax "very good at handling overlapping structures like mats of hair and crisscrossing bristles ... nicely avoiding the loss-of-detail halos typical of other stacking programs ... tends to increase noise and contrast, and it can alter colors somewhat"; DMap "does a better job keeping the original smoothness and colors ... not as good at finding and preserving detail"; "The two methods complement each other." Retouching transcript: "Generally PMax gives less halo and does a better job with overlapping bristles and faint details, while DMap does a better job of preserving the contrast and smooth tones." Retouching002: PMax output shows "quite a bit of pixel noise, much more than appeared in any of the source frames." Corroborated by photomacrography.net (t=35502), extreme-macro.co.uk, macrobyraghu.com, Allan Walls comparative testing.

**Sources:**
- https://zerenesystems.com/cms/stacker/docs/howtouseit
- https://zerenesystems.com/cms/stacker/docs/faqlist
- http://zerenesystems.com/stacker/docs/RetouchingTutorial/RetouchingTutorialTranscript.htm
- https://zerenesystems.com/cms/stacker/docs/videotutorials/retouching002/transcript

#### Pass 2-F2: high confidence (3-0 unanimous (claim 10))

PMax noise mechanism and mitigation: the noise amplification is attributed to the finest pyramid scale being unable to distinguish focused detail from pixel noise (max-selection then latches onto noise), and Zerene ships a default-on 'grit suppression' option that trades a small amount of fine detail for significantly less noise — a direct design lesson for any pyramid max-selection renderer: suppress or soft-select at the finest scale.

**Evidence:** FAQ: PMax "is relentless about preserving the sharpest detail at all size scales, but at the very finest scale it has trouble distinguishing between focused detail and pixel noise"; "The 'grit suppression' option, which is selected by default, makes a small sacrifice in saving fine detail, in exchange for the benefit of getting significantly less noise in the final image." Candid vendor admission of its own method's weakness, corroborated by photomacrography.net threads and practitioner guides.

**Sources:**
- https://zerenesystems.com/cms/stacker/docs/faqlist

#### Pass 2-F3: high confidence (3-0 unanimous on all merged claims (3, 4, 5, 12))

DMap spatial radii (merged): Estimation Radius sets the scale of detail used to decide which frame is in focus, and mis-setting it is a primary halo cause — too small yields hard-edged halos plus blotches in low-contrast areas; too large yields large loss-of-detail halos and missed fine features. Smoothing Radius controls how quickly rendering transitions between source frames, i.e. a soft blend band rather than hard per-pixel selection, with the documented rule of thumb Smoothing = Estimation/2. Concrete numbers: Estimation Radius = 5 for sharp motion-free stacks at 100% scale, scaled up in proportion to blur, or ~1/100–1/200 of image width when there is subject movement; higher radii for smooth low-detail subjects, lower for crisp high-contrast subjects.

**Evidence:** tutorial003: Estimation Radius too small → "hard-edged halos plus blotches in areas of low contrast"; too big → "large loss-of-detail halos and some fine features may be missed"; Smoothing Radius "controls how quickly DMap will switch from one source image to another"; "set Smoothing Radius equal to half the Estimation Radius." FAQ: "set Estimation Radius = 5" for sharp motion-free stacks; "1/100 and 1/200 of your image width" for movement; "set Smoothing Radius to half the value of Estimation Radius." howtouseit: larger radii for simple/low-detail subjects, smaller for crisp high-contrast detail. Corroborated by photomacrography.net t=34245.

**Sources:**
- http://zerenesystems.com/cms/stacker/docs/tutorials/tutorial003
- https://zerenesystems.com/cms/stacker/docs/howtouseit
- https://zerenesystems.com/cms/stacker/docs/faqlist

#### Pass 2-F4: high confidence (3-0 unanimous on all merged claims (2, 6, 11, 18))

DMap Contrast Threshold (merged): a percentile-based slider acting as a human-judgment confidence mask — it marks low-detail 'can't tell' regions where the depth map should favor smoothness (regularization) over unreliable focus measurements; internally it sets both a percentile and a detail level at the black/normal break. Tuning target: unfocused areas go black in preview while focused detail keeps normal colors. Too low (e.g. 0.0) → frame selection driven mostly by random noise, producing an 'ugly mess of blotches'/excessive artifacts; too high (e.g. 85.0) → real subject detail discarded with the noise. Since build T2015-07-10-1645-beta users can import a mask file that spatially augments the threshold (vendor rationale: white subjects on uniform dark backgrounds), showing Zerene treats per-region confidence control as a needed halo/blotch mitigation.

**Evidence:** FAQ: "using your human judgment to mark 'can't tell' regions where you want the program to emphasize smoothness rather than getting misled by pixel noise"; "you are actually setting two numbers: the percentile ... and the level ... at the break." tutorial003: too low "causes the frame selection to be determined mostly by random noise ... an ugly mess of blotches"; goal is unfocused areas black in preview. howtouseit: 0.0 → excessive junk/chunky regions; 85.0 → subject detail lost with noise. modificationhistory: "DMap: Now allows to import a mask file that augments the contrast threshold slider" (useful for white flowers on dark background). Corroborated by photomacrography.net t=29451, t=24356, t=34245.

**Sources:**
- https://zerenesystems.com/cms/stacker/docs/howtouseit
- http://zerenesystems.com/cms/stacker/docs/tutorials/tutorial003
- https://zerenesystems.com/cms/stacker/docs/faqlist
- https://zerenesystems.com/cms/stacker/docs/modificationhistory

#### Pass 2-F5: high confidence (3-0 unanimous on both merged claims (8, 16))

Documented hybrid workflow: Zerene explicitly recommends running both methods and retouching a DMap base from the PMax output to combine PMax's overlap/bristle handling with DMap's better colors, contrast, and noise — especially for hairy/bristly high-magnification subjects. This is the vendor's own answer to the fundamental per-pixel-selection limit, and it maps directly onto an automated hybrid: depth-map rendering everywhere, pyramid fusion substituted in flagged discontinuity/overlap regions.

**Evidence:** tutorial003: use "both DMap and PMax, then use human judgment and retouching to combine PMax's better handling of troublesome overlaps with DMap's better handling of colors, contrasts, and noise"; PMax "teases apart the overlap to essentially combine color information from the focused-petal image with luminance information from the focused-leaf image." Retouching tutorial: "DMap output often makes a good starting point, but ... has problems with bristles. PMax generally handles bristles quite well, so we select the PMax output as a retouching source."

**Sources:**
- http://zerenesystems.com/cms/stacker/docs/tutorials/tutorial003
- http://zerenesystems.com/stacker/docs/RetouchingTutorial/RetouchingTutorialTranscript.htm

#### Pass 2-F6: high confidence (3-0 unanimous on all merged claims (19, 20, 21))

Helicon Focus's three methods span the full rendering-strategy design space: Method A is energy-weighted blending (per-pixel weight from local contrast, all frames averaged by weight — not hard selection); Method B is hard per-pixel depth-map selection (picks the single source image with the sharpest pixel) and requires consecutive front-to-back shooting order; Method C is pyramid fusion, officially recommended for complex scenes (intersecting objects, edges, deep stacks) but documented to increase contrast and glare — the same amplification behavior Zerene documents for PMax, confirming pyramid contrast/noise amplification across two independent implementations.

**Evidence:** Main-parameters page: "Method A computes the weight for each pixel based on its contrast, after which all the pixels from all the source images are averaged according to their weights"; "Method B finds the source image where the sharpest pixel is located and creates a 'depth map' ... requires that the images be shot in consecutive order from front to back or vice versa"; "Method C uses a pyramid approach ... good results in complex cases (intersecting objects, edges, deep stacks) but increases contrast and glare." Recommendation table: for crossing lines "Method A and C excel; Method B is not recommended"; for >100-image stacks B and C preferable; C unsuitable when glare present.

**Sources:**
- https://www.heliconsoft.com/helicon-focus-main-parameters/
- https://www.heliconsoft.com/focus/help/english/HeliconFocus.html

#### Pass 2-F7: high confidence (3-0 unanimous on both merged claims (22, 23))

Helicon's two tunable parameters directly encode the halo levers: Radius (window size for per-pixel contrast, methods A/B) trades halo vs detail — small radii (3-5) preserve fine detail but produce more noise and halo, and the documented halo mitigation is to increase radius until halo is minimized, then stop to preserve detail. Smoothing controls how selected regions transition: low smoothing → sharper result but visible artifacts at transition (depth-discontinuity) areas; high smoothing → no visible transitions at the cost of slight blur. Defaults Radius 8 / Smoothing 4 mirror Zerene's Smoothing = Estimation/2 rule — independent convergence on a small blend window around hard selection as the transition-artifact mitigation.

**Evidence:** Main-parameters page: "The radius parameter defines the number of pixels around each pixel that are used to calculate its contrast"; low radius (3-5) best for fine detail "although you will probably get more noise and a halo effect"; "if you have a halo effect, try increasing the radius until doing so helps to minimize halo. At that point, stop increasing the radius, so as to preserve as much detail as possible"; "Low smoothing produces a sharper image, but the transition areas may have some artifacts. High smoothing will result in a slightly blurry image without any visible transition areas." Help PDF: Method B defaults Radius 8 / Smoothing 4. Corroborated by Helicon forum threads t=11328/t=11445 (radius 16-30+ for halos) and srussenschuck.com.

**Sources:**
- https://www.heliconsoft.com/helicon-focus-main-parameters/
- https://www.heliconsoft.com/focus/help/english/HeliconFocus.pdf

#### Pass 2-F8: high confidence (Derived from 3-0 verified claims; the recommendation itself is synthesis, not a verified claim)

Concrete guidance derived from the converged evidence — (a) Rendering: use hard per-pixel argmax selection from the depth map softened by a small blend band (tent/soft transition sized ~half the focus-measure window), matching both vendors' shipped designs; reserve energy/contrast-weighted averaging (Method-A-style) or pyramid fusion for low-confidence and overlap regions, since pure weighted averaging sacrifices sharpness and pure pyramid max amplifies noise/contrast. (b) Render-time halo mitigations, in priority order: scale the focus-measure radius to blur (increase to shrink halos, stop when detail loss begins); gate depth values by a contrast/confidence threshold and regularize toward smoothness in 'can't tell' regions; keep the blend band at discontinuities; if adding a pyramid path, implement finest-scale grit suppression; support per-region confidence masks; and accept that discontinuity halos where defocused foreground occludes background are optically unfixable by selection — flag those regions rather than promising to fix them.

**Evidence:** Synthesis of the findings above: two independent commercial implementations converge on depth-map hard selection + smoothing band as the default (Zerene DMap Smoothing = Estimation/2; Helicon Method B Radius 8/Smoothing 4), both document pyramid max-selection amplifying noise/contrast/glare, both document radius-vs-halo tradeoff and confidence thresholding, and Zerene documents both the fundamental optical limit and the DMap-base/PMax-source hybrid as the practical remedy.

**Sources:**
- https://zerenesystems.com/cms/stacker/docs/faqlist
- http://zerenesystems.com/cms/stacker/docs/tutorials/tutorial003
- https://www.heliconsoft.com/helicon-focus-main-parameters/

#### Pass 2-F9: high confidence (N/A — meta-finding about evidence coverage)

Question areas 3 and 4 (multi-focus fusion quality metrics Q_AB/F, mutual information, SSIM-based metrics, Lytro/MFI-WHU/MFFW benchmarks, and 2020+ Core ML-portable deep fusion / depth-from-focus models) produced zero claims that survived adversarial verification — the confirmed evidence set covers only the product-behavior and practitioner half of the research question, so no metric or model recommendation for the synthetic regression suite can be made from this material.

**Evidence:** All 24 surviving claims concern Zerene and Helicon documentation and practitioner behavior; none address fusion metrics, benchmark datasets, or deep-learning models. Absence of surviving claims does not mean absence of literature — it means these sub-questions were either not researched or their claims failed verification, and they require a follow-up pass against the primary papers (Xydeas & Petrovic 2000; Nejati et al. Lytro dataset; MFI-WHU; MFFW).

### Caveats

1) Coverage gap: sub-questions 3 (fusion quality metrics/benchmarks) and 4 (Core ML-portable deep models) have no surviving verified claims, so recommendation (c) — which metrics to add to the regression suite — is unsupported by this evidence set and stated only as an open item. 2) Source concentration: nearly all findings rest on vendor documentation (zerenesystems.com, heliconsoft.com). These are candid, self-critical primary sources (documenting their own methods' failure modes), and practitioner forums corroborate them, but exact algorithms (contrast measures, weight normalization, pyramid details) are proprietary and described only at a high level — implementation guidance is behavioral, not algorithmic. 3) One claim was refuted (2-1): the alleged T2011-09-15 changelog entry changing DMap defaults from 5/2 to 10/5; the half-ratio rule itself is independently confirmed, but specific historical default values should not be cited. 4) Attribution nuance in finding 1: Zerene's transcript ties broad dark halos specifically to PMax and the low-detail-background worsening to DMap's threshold stage; the merged statement is accurate but loses per-method attribution. 5) Time-sensitivity is low — Zerene/Helicon algorithms and docs have been stable for over a decade and pages were live as of 2026-07 — but any deep-learning follow-up (question 4) is fast-moving and would need fresh research. 6) 'Inherently increases noise' slightly strengthens the vendors' hedged 'tends to'; direction and mechanism are solid, magnitude is scene-dependent.

### Refuted claims (do NOT rely on these)

- **(1-2)** In build T2011-09-15-0905, Zerene Stacker changed the default DMap parameters from Estimation Radius = 5 / Smoothing Radius = 2 to Estimation Radius = 10 / Smoothing Radius = 5, stating the new values work better for new users and 10+ megapixel cameras — confirming these are the two tunable spatial radii governing DMap's depth-map estimation and smoothing.
  - source: https://zerenesystems.com/cms/stacker/docs/modificationhistory

### Open questions (unresearched or unverified)

- Which multi-focus fusion metrics (Q_AB/F, MI, SSIM-based) actually transfer to regression-testing a photographic tool against synthetic ground truth — and do any correlate with perceived halo severity specifically? This half of the research question remains unanswered and needs a dedicated pass on the primary metric papers and the Lytro/MFI-WHU/MFFW dataset papers.
- Are there 2020+ boundary-aware fusion or depth-from-focus networks (small U-Nets, GRU refiners over classical focus volumes) with permissive licenses and demonstrated Core ML/Apple Silicon ports, and what are their parameter counts and latencies?
- What is the exact blend kernel/window shape behind Zerene's Smoothing Radius and Helicon's Smoothing parameter (linear/tent vs Gaussian vs sigmoid over depth indices), and does kernel shape measurably affect transition artifacts — worth an ablation in our own renderer?
- Can the documented manual hybrid (DMap base retouched from PMax in overlap regions) be automated via a discontinuity/overlap detector that switches to depth-constrained Laplacian-pyramid fusion locally, and does it quantitatively beat either pure method on synthetic stacks with known occlusion boundaries?

### All sources fetched

- [primary] https://zerenesystems.com/cms/stacker/docs/howtouseit (angle: Primary product docs — Zerene Stacker, 5 claims)
- [primary] http://zerenesystems.com/cms/stacker/docs/tutorials/tutorial003 (angle: Primary product docs — Zerene Stacker, 5 claims)
- [primary] https://zerenesystems.com/cms/stacker/docs/faqlist (angle: Primary product docs — Zerene Stacker, 5 claims)
- [primary] https://zerenesystems.com/cms/stacker/docs/videotutorials/retouching002/transcript (angle: Primary product docs — Zerene Stacker, 5 claims)
- [primary] http://zerenesystems.com/stacker/docs/RetouchingTutorial/RetouchingTutorialTranscript.htm (angle: Primary product docs — Zerene Stacker, 4 claims)
- [primary] https://zerenesystems.com/cms/stacker/docs/modificationhistory (angle: Primary product docs — Zerene Stacker, 5 claims)
- [primary] https://www.heliconsoft.com/helicon-focus-main-parameters/ (angle: Primary product docs — Helicon Focus, 5 claims)
- [primary] https://www.heliconsoft.com/focus/help/english/HeliconFocus.html (angle: Primary product docs — Helicon Focus, 5 claims)
- [primary] https://www.heliconsoft.com/focus/help/english/Helicon_Focus_Help_Eng.pdf (angle: Primary product docs — Helicon Focus, 5 claims)
- [forum] https://forum.heliconsoft.com/viewtopic.php?t=10512 (angle: Primary product docs — Helicon Focus, 5 claims)
- [blog] https://srussenschuck.com/focus-stacking-part-2-artefacts/ (angle: Primary product docs — Helicon Focus, 5 claims)
- [forum] https://www.photomacrography.net/forum/viewtopic.php?p=102557 (angle: Practitioner experience and artifact taxonomy, 5 claims)
- [blog] http://extreme-macro.co.uk/zerene-slabbing/ (angle: Practitioner experience and artifact taxonomy, 5 claims)
- [blog] https://www.allanwallsphotography.com/blog/dreaded%20halo (angle: Practitioner experience and artifact taxonomy, 5 claims)
- [primary] https://journals.plos.org/plosone/article?id=10.1371%2Fjournal.pone.0191085 (angle: Academic/technical — fusion algorithms and rendering strategy, 5 claims)
- [primary] https://www.mdpi.com/2076-3417/12/12/6281 (angle: Academic/technical — fusion algorithms and rendering strategy, 5 claims)
- [primary] https://github.com/xingchenzhang/MFIF (angle: Metrics, benchmarks, and deployable deep models, 5 claims)
- [primary] https://www.mdpi.com/2076-3417/15/13/7500 (angle: Metrics, benchmarks, and deployable deep models, 5 claims)
- [primary] https://arxiv.org/pdf/1904.00198 (angle: Metrics, benchmarks, and deployable deep models, 5 claims)
- [primary] https://arxiv.org/abs/2108.10843 (angle: Metrics, benchmarks, and deployable deep models, 5 claims)
- [primary] https://www.researchgate.net/publication/3381966_Objective_image_fusion_performance_measure (angle: Metrics, benchmarks, and deployable deep models, 5 claims)
- [primary] https://www.researchgate.net/publication/291522937_Lytro_Multi-focus_Image_Dataset (angle: Metrics, benchmarks, and deployable deep models, 4 claims)

### Verification stats

`{"angles": 5, "sourcesFetched": 22, "claimsExtracted": 108, "claimsVerified": 25, "confirmed": 24, "killed": 1, "unverified": 0, "afterSynthesis": 10, "urlDupes": 6, "budgetDropped": 2, "agentCalls": 104}`

## Pass 1 — academic: focus measures & depth regularization

### Question

```
Focus stacking (multi-focus image fusion) algorithms for a production macro-photography tool: everything needed to design a depth-map-based fusion pipeline that matches or beats Helicon Focus and Zerene Stacker on difficult real stacks (glossy subjects with specular bokeh, low-texture receding substrates, 100-200 frame stacks at 45 MP).

Context of our existing pipeline (open-source macOS app "Hyperfocal"): per-pixel focus measure = gaussian-smoothed |Laplacian| of luminance; per-pixel argmax across frames with confidence gating (noise floor on energy, plus a "peak concentration" test that rejects pixels whose above-median energy is spread across many frames — suppresses defocused specular bokeh rims); no-signal regions fill by jump-flood nearest-confident-seed (Voronoi) with a second pass re-deriving each basin's depth from its aggregate energy curve; depth map then cleaned by confidence-weighted median; rendering samples frames along the depth map with a tent kernel (radius ~1 frame). Planned next steps we want validated/challenged: (a) replace fill geometry with a confidence-weighted push-pull / multi-scale pyramid over depth votes; (b) weight the render blend by per-frame local energy so the sharpest content within a depth neighborhood wins (suspected to be how Helicon tolerates coarse depth and suppresses halos).

Research questions:
1. Focus measure operators: comparative evidence (survey papers, benchmarks) for Laplacian variants, modified Laplacian (SML), Tenengrad, ring difference filters, wavelet/DCT energy, deep-learned measures — especially robustness to defocused specular highlights (bokeh) and low-contrast texture.
2. Depth-map regularization in depth-from-focus / shape-from-focus literature: MRF/graph-cut formulations, guided/joint-bilateral filtering, weighted least squares, anisotropic diffusion, push-pull scattered-data interpolation — what's proven for filling textureless regions without halos at depth discontinuities, and what's practical at 45 MP on consumer GPUs.
3. Halo/edge-bleed artifacts at depth discontinuities in focus stacking: known causes and mitigation techniques in both academic literature and practitioner knowledge (Zerene PMax vs DMap behavior, Helicon methods A/B/C internals as far as publicly documented, retouching workflows).
4. Rendering/blending: hard selection vs weighted averaging, multi-scale (Laplacian pyramid) fusion hybrids with depth maps, contrast-weighted blending — evidence on sharpness preservation vs artifact suppression, including noise amplification behavior.
5. Multi-focus fusion benchmarks/datasets and objective quality metrics (Q_AB/F, MI, SSIM-based) used to compare methods — anything applicable to synthetic ground-truth regression like ours.
6. Any recent (2020+) deep learning approaches practical for on-device use (Core ML on Apple Silicon) worth tracking, vs classical methods.
Prioritize: primary literature (surveys + seminal papers with citation counts), documented behavior of Zerene/Helicon from their own docs/forums, and practitioner sources (photomacrography.net forums etc). Output should give concrete algorithmic recommendations mapped to our pipeline's stages.
```

### Summary

The verified literature strongly supports Hyperfocal's Laplacian-based focus measure as a clean-conditions baseline, but identifies its two documented weaknesses — worst-in-class noise sensitivity and rapid degradation at small evaluation windows / low texture — and points to concrete upgrades: multi-scale directional dilated Laplacian kernels (DDL) or the Ring Difference Filter, both of which beat plain Laplacian under noise while retaining localization, plus statistics-based (variance/PCA) or Tenengrad measures as noise-robust confidence-gating complements. For depth-map regularization, the evidence favors regularizing earlier in the pipeline than Hyperfocal currently does: cost-volume aggregation (RDF-style), separable 3D weighted-least-squares on the focus volume, or joint variational/graph-cut estimation all outperform post-hoc geometric fill, and guided filtering with a carefully chosen guidance map (all-in-focus image or focus-volume correlation as structural prior) is a validated, GPU-practical depth-map refiner whose soft-confidence behavior naturally subsumes the jump-flood Voronoi fill stage. The variational literature also validates the planned direction of treating low-contrast regions as soft-weighted rather than binary no-signal, letting a regularizer set depth where the data term is weak. Notably, no claims survived on halo mechanics, Helicon/Zerene internals, rendering/blending strategy, fusion quality metrics, or on-device deep learning — those research questions remain open, and the one claim asserting joint estimation is "markedly better" than compute-then-smooth was refuted, so the case for restructuring the pipeline (vs. upgrading each stage) is suggestive but not proven.

### Verified findings

#### Pass 1-F0: high confidence (3-0)

Laplacian-based focus measures are the best-performing family for depth-from-focus under normal imaging conditions (no noise, contrast reduction, or saturation), validating Hyperfocal's gaussian-smoothed |Laplacian| as a sound baseline — but only as an ideal-conditions baseline.

**Evidence:** Pertuz, Puig & Garcia (Pattern Recognition 2013, ~784 citations), the standard 36-operator SFF benchmark: 'Laplacian-based operators have the best overall performance at normal imaging conditions.' The same paper cautions that per-condition rankings depend on the capture device, and that Laplacian operators degrade above ~30% saturation — directly relevant to specular macro highlights.

**Sources:**
- https://www.sciencedirect.com/science/article/abs/pii/S0031320312004736

#### Pass 1-F1: high confidence (3-0 (merged from claims 1, 7, 8, 6))

Laplacian-based operators are the most noise-sensitive focus-measure family; statistics-based operators (best: eigenvalue/PCA-based STA2) are the most noise-robust and become the most accurate at moderate-to-high noise, with gradient-based GRA7 second at the highest noise level; among gradient operators specifically, Tenengrad shows the best noise robustness (RRMSE 0.0726 vs 0.6012 for EOG). These are candidates to complement or gate the Laplacian measure on noisy 45 MP captures.

**Evidence:** Merged from three unanimous claims. Pertuz et al. Section 4.2.2 verbatim: 'statistics-based operators have the highest robustness to noise, with the STA2 operator being the best... Laplacian-based operators... are the most sensitive to noise.' Independently corroborated by a 2025 RRMSE robustness study (variance operator best in noise robustness; Tenengrad best among gradient operators, from a pathology-microscopy autofocus context). Caveat: statistics-based robustness holds only while noise variance stays below signal variance, and Laplacian remains best at low noise — variance is a complement, not a universal winner.

**Sources:**
- https://www.sciencedirect.com/science/article/abs/pii/S0031320312004736
- https://sites.google.com/view/cvia/focus-measure
- https://pmc.ncbi.nlm.nih.gov/articles/PMC12115465/

#### Pass 1-F2: high confidence (3-0 (merged from claims 2, 9))

Evaluation-window size is a spatial-resolution vs texture-robustness trade-off: as the window shrinks, Laplacian- and gradient-based operators deteriorate quickly (LAP2 relative quality 1.00 at 7x7 → 0.26 at 3x3) while wavelet-based operators stay robust (0.98 → 0.96) — directly relevant to choosing Hyperfocal's Gaussian smoothing radius on low-texture receding substrates.

**Evidence:** Merged from two unanimous claims on the same benchmark. Pertuz et al.: 'the optimum window size... must be a trade-off between spatial resolution and robustness to the lack of texture... the response of the Laplacian-based operator quickly deteriorates, while the wavelet-based operator responds more robustly.' Practical caveat for 45 MP: wavelet operators cost ~8-20x more than Laplacian (WAV1 55 ms vs LAP2 7.2 ms in the paper's timing table).

**Sources:**
- https://www.sciencedirect.com/science/article/abs/pii/S0031320312004736
- https://sites.google.com/view/cvia/focus-measure

#### Pass 1-F3: high confidence (3-0 (merged from claims 3, 4, 5))

The Ring Difference Filter (RDF; Jeon et al., IEEE TIP 2019, with public code) is a focus measure whose ring-and-disk kernel combines the localization accuracy of local measures (Laplacian variants) with the noise robustness of non-local measures; its pipeline regularizes by RDF-based aggregation of the focus-measure cost volume (before depth selection) rather than post-hoc geometric fill, and the authors report results on par with or better than 2017-2019 state-of-the-art DfF at lower compute cost.

**Evidence:** Merged from three unanimous claims, all verified verbatim against the abstract (PubMed PMID 31478856) and the official implementation (github.com/jaeheungs/rdf_depth_from_focus, which exposes cost-volume-stage RDF aggregation). Directly supports Hyperfocal's plan to replace jump-flood Voronoi fill with confidence-weighted aggregation over depth votes — but at the cost-volume stage, not the depth-map stage. Caveats: later deep methods surpass RDF on depth benchmarks; experiments were far below 45 MP x 100-200 frames; the full pipeline also includes depth-map-level steps (unreliable-depth rejection, tree propagation, weighted median); the directional-RDF follow-up notes RDF suffers the response-cancellation problem.

**Sources:**
- https://ieeexplore.ieee.org/document/8818667/

#### Pass 1-F4: medium confidence (3-0 (merged from claims 10, 11))

Multiscale directional dilated Laplacian (DDL) focus measures — 1-D second-difference kernels applied in 4 directions at dilation rates 1-4 with per-direction absolute responses summed to avoid cancellation — are more robust to Gaussian, salt-and-pepper, and speckle noise than both a standard 3x3 Laplacian and RDF under classical per-pixel argmax, with accuracy improving as larger dilations are added. The dilation choice is texture-dependent: on clean synthetic stacks higher dilation over-smooths fine detail, but on real captures larger dilations help even without added noise (authors pick cumulative r=4).

**Evidence:** Merged from two unanimous claims, verified against the full PDF (Ashfaq & Mahmood, accepted at IJCV 2026, evaluated on HCI/LFSD/FlyingThings3D, 1200+ focal stacks). Consistent with Pertuz et al.'s window-size findings and RDF's receptive-field rationale, but a single self-reported ablation with no independent replication, mild noise levels (Gaussian var 1e-4), and 'often outperformed' hedging for the simplest variant. A cheap, drop-in upgrade path for Hyperfocal's operator: cumulative multi-scale dilated kernels rather than a single Gaussian smoothing radius.

**Sources:**
- https://arxiv.org/pdf/2512.10498

#### Pass 1-F5: medium confidence (3-0)

Collapsing the focus volume to depth in one step (per-pixel argmax or softmax aggregation) amplifies noise and blurs depth discontinuities; the same paper's iterative multi-scale GRU refinement at reduced resolution with learned convex upsampling cut MAE from ~5.5 to 2.70 on FlyingThings3D when fed the same DDL focus volume (Acc@1.25 from ~86% to 95.4%).

**Evidence:** Verified against Table 2 of the IJCV-accepted paper (AiFDNet 5.45, DFV-FV 5.58, GRU 2.70 MAE). Single-source, synthetic-data, authors' own ablation, and baseline inputs were equivalent-in-spirit rather than byte-identical. Relevant as the deep-learning direction to track for Core ML: a small recurrent refiner over a classical focus volume at reduced resolution is a plausible on-device architecture, though 45 MP feasibility is untested.

**Sources:**
- https://arxiv.org/pdf/2512.10498

#### Pass 1-F6: high confidence (3-0 (merged from claims 13, 14, 15, 21))

Guided image filtering is a validated, practical post-hoc regularizer for SFF depth maps: it measurably improves initial depth maps on synthetic and real sequences; multiple guided-filter variants have been systematically ranked for SFF; the guidance map is a distinct design variable that materially affects results (best performers: mean image intensity and focus-volume/intensity correlation); and a 2022 follow-up implements WLS regularization via guided filtering with local variations of the all-in-focus image as the structural prior, so depth edges align with image edges.

**Evidence:** Merged from four unanimous claims across two peer-reviewed papers (Ali et al., Pattern Recognition 2021; CVIU 2022). This maps directly onto Hyperfocal's confidence-weighted-median cleanup stage: replace or augment it with guided filtering using the fused (AIF) image as guide. Key caveat from the verifiers: plain fixed-regularization GIF can itself introduce halos near depth edges (the stated motivation for the adaptive-weighted AWGIF follow-up, Pattern Recognition 2022) — use an edge-adaptive variant given the halo focus of this project.

**Sources:**
- https://www.sciencedirect.com/science/article/abs/pii/S0031320320304738
- https://www.sciencedirect.com/science/article/abs/pii/S1077314222001977

#### Pass 1-F7: medium confidence (3-0 (merged from claims 16, 17))

Regularizing the full 3D focus volume before depth selection — via 3D weighted least squares using the image sequence itself as guidance volume — improves SFF depth accuracy over conventional per-slice smoothing, and is computationally tractable because the global solve decomposes into sequences of 1-D tridiagonal (three-point Laplacian) sub-problems per dimension, following Min et al.'s fast global smoother.

**Evidence:** Merged from two unanimous claims on one peer-reviewed paper (Ali, Pruks & Mahmood, Information Sciences 2019), corroborated by the well-cited separable-WLS antecedent (Min et al., IEEE TIP 2014) and follow-up work that builds on it. The separable tridiagonal structure is what makes cost-volume regularization plausibly GPU-feasible, but the paper's experiments are small microscopy sequences; memory for a 45 MP x 100-200 frame focus volume (tens of GB at fp16) is unaddressed and would require tiling or reduced-resolution volumes. Also noted: the authors' later nonconvex volume regularization (IEEE TIP 2021) supersedes 3D-WLS in accuracy.

**Sources:**
- https://www.sciencedirect.com/science/article/abs/pii/S0020025519302695

#### Pass 1-F8: high confidence (3-0 (merged from claims 18, 19, 20))

Global-optimization formulations of depth-from-focus are established: (a) a variational model with a nonconvex per-pixel negative-contrast data term plus convex isotropic TV regularization beats classical windowed-filtering MLAP on all four simulated shapes (Plane RMSE 1.01-1.26 vs 5.14-9.87) and handles textureless regions as soft/fuzzy confidence weighting — low contrast exerts little data-term force, so the regularizer sets depth there automatically; (b) SFF depth estimation can also be posed as global minimization of a convex functional solved exactly via a sequence of binary graph-cut problems with a global-optimality guarantee over the discretized labels.

**Evidence:** Merged from three unanimous claims across two peer-reviewed papers (Moeller et al., IEEE TIP 2015; Ribal et al., JVCIR 2018). The soft-confidence mechanism directly validates Hyperfocal's direction of replacing binary no-signal fill with weighted regularization. Important limits: the TV comparison is against simple baselines on the authors' own synthetic data, and TV 'fill' imposes a piecewise-smooth prior (staircasing) — automatic fill, not guaranteed-correct fill; later work notes depth remains ill-posed in textureless regions. Two adjacent stronger claims were refuted 0-3: that joint estimation is 'markedly better' than compute-then-smooth, and that the graph-cut method is demonstrated robust to corrupted focus data.

**Sources:**
- https://arxiv.org/pdf/1408.0173
- https://www.sciencedirect.com/science/article/abs/pii/S104732031830155X

### Caveats

Coverage gaps are the biggest caveat: no claims survived on research questions 3 (halo causes/mitigation, Zerene PMax/DMap and Helicon A/B/C behavior, practitioner knowledge), 4 (hard selection vs weighted blending, Laplacian-pyramid hybrids, noise amplification), or 5 (fusion benchmarks and Q_AB/F, MI, SSIM metrics) — so the planned energy-weighted render blend (next step b) and the hypothesis about how Helicon tolerates coarse depth remain unvalidated by this evidence set. Domain transfer is uniformly unproven: every surviving source works on microscopy, light-field, or small synthetic SFF stacks at resolutions far below 45 MP x 100-200 frames, so runtime and memory feasibility claims are suggestive only. Specular-bokeh robustness specifically was never directly tested by any source; the closest evidence is Pertuz's saturation-sensitivity finding for Laplacian operators. Three refuted claims matter for interpretation: the superiority of joint estimation over compute-then-smooth (0-3) means the case for restructuring Hyperfocal's pipeline order is weaker than the surviving variational claims might suggest. The DDL/GRU findings (Dec 2025, IJCV-accepted) are single-source self-ablations with no independent replication yet. Guided filtering, the best-supported depth-map regularizer, carries its own documented halo risk in its plain form — the adaptive-weighted variants exist precisely because of that.

### Refuted claims (do NOT rely on these)

- **(1-2)** SML and EOL are the most sensitive focus measure operators of the 12 tested (steep slope width, peak curvature), but both are suboptimal in noise robustness — relevant to Hyperfocal's choice of a Laplacian-energy focus measure, which buys sharpness discrimination at the cost of noise sensitivity.
  - source: https://pmc.ncbi.nlm.nih.gov/articles/PMC12115465/
- **(0-3)** Regularizing jointly with the contrast data term is markedly better than the compute-depth-then-smooth pipeline (as Hyperfocal currently does with confidence-weighted median): applying TV denoising to an already-computed depth map cannot cheaply remove large regions erroneously mapped to the foreground, whereas the joint approach can, because relabeling costs little wherever contrast shows no strong preference.
  - source: https://arxiv.org/pdf/1408.0173
- **(0-3)** The graph-cut approach is claimed to be robust to corrupted focus-measure data (i.e., unreliable per-pixel focus responses such as low-texture regions), demonstrated quantitatively on standard real datasets.
  - source: https://www.sciencedirect.com/science/article/abs/pii/S104732031830155X

### Open questions (unresearched or unverified)

- How do Helicon Focus methods A/B/C and Zerene PMax/DMap actually behave at depth discontinuities and on specular bokeh, and does Helicon's tolerance of coarse depth maps really come from local-energy-weighted blending within a depth neighborhood? No documentation or practitioner evidence survived verification.
- What is the memory/runtime feasibility of cost-volume-level regularization (separable 3D-WLS, RDF aggregation, or GRU refinement) at 45 MP x 100-200 frames on Apple Silicon — does tiled or reduced-resolution processing preserve the accuracy gains reported at small scale?
- Which rendering strategy (hard selection, tent-kernel depth sampling, energy-weighted blend, or Laplacian-pyramid fusion guided by the depth map) best trades sharpness preservation against halo and noise amplification? The blending literature produced no surviving claims.
- Are there fusion-quality benchmarks or metrics (Q_AB/F, MI, SSIM-based) with synthetic ground truth that transfer to macro-photography regression testing, and do any 2020+ deep multi-focus-fusion models convert practically to Core ML?

### All sources fetched

- [primary] https://www.sciencedirect.com/science/article/abs/pii/S0031320312004736 (angle: academic-survey/focus-measures, 5 claims)
- [primary] https://ieeexplore.ieee.org/document/8818667/ (angle: academic-survey/focus-measures, 4 claims)
- [primary] https://pmc.ncbi.nlm.nih.gov/articles/PMC12115465/ (angle: academic-survey/focus-measures, 5 claims)
- [primary] https://sites.google.com/view/cvia/focus-measure (angle: academic-survey/focus-measures, 5 claims)
- [primary] https://arxiv.org/pdf/2512.10498 (angle: academic-survey/focus-measures, 5 claims)
- [blog] https://opencv.org/blog/autofocus-using-opencv-a-comparative-study-of-focus-measures-for-sharpness-assessment/ (angle: academic-survey/focus-measures, 5 claims)
- [primary] https://www.sciencedirect.com/science/article/abs/pii/S0031320320304738 (angle: academic/depth-regularization, 5 claims)
- [primary] https://www.sciencedirect.com/science/article/abs/pii/S0020025519302695 (angle: academic/depth-regularization, 5 claims)
- [primary] https://arxiv.org/pdf/1408.0173 (angle: academic/depth-regularization, 5 claims)
- [primary] https://www.sciencedirect.com/science/article/abs/pii/S104732031830155X (angle: academic/depth-regularization, 5 claims)
- [primary] https://www.sciencedirect.com/science/article/abs/pii/S1077314222001977 (angle: academic/depth-regularization, 5 claims)
- [primary] https://www.sciencedirect.com/science/article/abs/pii/S0031320320301060 (angle: academic/depth-regularization, 5 claims)
- [blog] https://srussenschuck.com/focus-stacking-part-2-artefacts/ (angle: practitioner/commercial-tools-halos, 5 claims)
- [forum] https://www.photomacrography.net/forum/viewtopic.php?t=13302 (angle: practitioner/commercial-tools-halos, 5 claims)
- [blog] https://www.allanwallsphotography.com/blog/zereneorheliconpt2 (angle: practitioner/commercial-tools-halos, 5 claims)
- [primary] http://xudongkang.weebly.com/uploads/1/6/4/6/16465750/tip1.pdf (angle: algorithmic/blending-fusion-hybrids, 5 claims)
- [primary] https://journals.plos.org/plosone/article?id=10.1371%2Fjournal.pone.0191085 (angle: algorithmic/blending-fusion-hybrids, 5 claims)
- [primary] https://github.com/xingchenzhang/MFIF (angle: benchmarks/metrics/recent-DL, 5 claims)
- [primary] https://arxiv.org/abs/2003.12779 (angle: benchmarks/metrics/recent-DL, 5 claims)
- [primary] https://www.sciencedirect.com/science/article/abs/pii/S0925231224018964 (angle: benchmarks/metrics/recent-DL, 4 claims)
- [primary] https://digital-library.theiet.org/doi/10.1049/el%3A20000267 (angle: benchmarks/metrics/recent-DL, 5 claims)

### Verification stats

`{"angles": 5, "sourcesFetched": 21, "claimsExtracted": 103, "claimsVerified": 25, "confirmed": 22, "killed": 3, "unverified": 0, "afterSynthesis": 9, "urlDupes": 3, "budgetDropped": 6, "agentCalls": 103}`
