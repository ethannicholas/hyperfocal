---
name: third-party-deps
description: Vet and correctly integrate any third-party software before it enters the tree or a shipped binary. Use BEFORE adding a SwiftPM/vcpkg/apt dependency, vendoring source into Vendor/ or Sources/, adding a #include for a new external library, pulling in a header-only lib, adding a Qt module, or copying code from GitHub/Stack Overflow/an LLM. Confirms the license is compatible with the distribution model (MIT source + paid app-store builds) and drives the required attribution/notice work in the same change. Invoke on any "add/pull in/use <library>" request, not after the fact.
---

# Including third-party software in Hyperfocal

The rule that motivates this skill: **never pull third-party code into the tree
or a shipped binary before confirming its license fits our distribution model,
and never defer the license's required paperwork to "later."** A GPL library
slipped in unchecked once (exiv2, caught in the 2026-07-23 audit and ripped
back out) — that must not recur.

Applies to *anything* that ends up in the repo or a distributed artifact: a new
`Package.swift` dependency, a vcpkg/apt library, source vendored under `Vendor/`
or `Sources/…`, a header-only lib, a new Qt module, npm/pip if ever, and
copy-pasted snippets from GitHub/Stack Overflow/an LLM (those carry licenses
too). "It's just a small header" is not an exemption.

## Our distribution model (what compatibility is judged against)

- Hyperfocal's own code is **MIT**; the source is public on GitHub.
- Paid, **reproducible** builds ship on the **Mac App Store** and **Microsoft
  Store** (DRM'd channels), plus direct download.
- Two binaries link different things: the **macOS** build is native (Apple
  frameworks; bundles only the Adobe DNG SDK + zlib), the **Windows/Linux**
  build uses the Qt shell + `Sources/CImaging` (LibRaw, OpenCV, libtiff, libpng,
  libjpeg-turbo, lcms2, easyexif). A dependency's obligations depend on *which
  binary ships it* and whether it's linked **dynamically or statically**.

## Step 1 — Identify the license FIRST (before any integration code)

Find the SPDX id from the project's **own** `LICENSE`/`COPYING`/source headers —
not from memory and not from a blog. Note the exact version. If a `Package.swift`
`license` field, vcpkg `vcpkg.json`, or SPDX headers exist, quote them.

## Step 2 — Judge it against the model

| Class | Examples | Verdict |
|---|---|---|
| ✅ **Permissive** | MIT, BSD-2/3-Clause, Apache-2.0, ISC, Zlib, libpng, Unlicense | **Fine.** Attribution only. |
| ⚠️ **Weak / file-level copyleft** | LGPL-2.1/3.0, MPL-2.0, CDDL-1.0, EPL | **Usable but conditional** — real work (see below). Never *static*-link LGPL. |
| 🛑 **Strong copyleft** | GPL-2.0/3.0, **AGPL** | **STOP — do not integrate.** |
| 🔀 **Dual-licensed** | "LGPL OR CDDL", "MIT OR Apache-2.0" | Elect the most permissive compatible arm; **document the election**. |
| ❓ **Custom / none / non-commercial** | "free for non-commercial use", no LICENSE, bespoke EULA | **STOP and ask the user.** |

Why 🛑 is a hard stop: linking GPL (even *dynamically* — the FSF makes no
static/dynamic distinction) makes the **whole shipped binary GPL**, which (a)
contradicts our MIT license and (b) can't ship on app stores — store DRM is a
"further restriction" GPL §6 forbids (the VLC-App-Store precedent). AGPL adds a
network-use trigger and is worse. There is no compliant way to put GPL code in
our store builds; find a permissive or dual-licensed alternative, or escalate.

**The confirmation gate:** if the license is anything other than clearly
permissive — i.e. copyleft (any GPL/LGPL/MPL/CDDL/EPL), dual-licensed, custom,
non-commercial, unclear, or absent — **stop and confirm with the user before
integrating.** Don't pull it in and clean up afterward.

Also check: **trademark** limits (don't imply endorsement; e.g. the Adobe/DNG
marks) and **patent-encumbered algorithms** (e.g. OpenCV SURF is still
encumbered; SIFT is free post-2020) even when the surrounding license is fine.

## Step 3 — Do the license's required work IN THE SAME change

Not a follow-up. Part of the commit that adds the dependency:

- **Vendored source:** keep the upstream `LICENSE` beside it and retain per-file
  notices. Exclude the LICENSE file from compilation in `Package.swift` (see the
  `easyexif` target's `exclude:` for the pattern). Reference the exact upstream
  commit/version.
- **`NOTICE.md`:** add an entry under the right platform section — component,
  version, SPDX license, copyright line(s), and any **mandatory verbatim string**
  reproduced exactly (e.g. libjpeg-turbo's "based in part on the work of the
  Independent JPEG Group", libtiff's Berkeley/LZW acknowledgment, advertising
  clauses).
- **`licenses/`:** if it introduces a standard long license not already there
  (Apache-2.0, LGPL/GPL-3.0, CDDL-1.0, MPL-2.0…), add the full text — the
  Windows build must *bundle* these.
- **Dual license:** state the elected arm in `NOTICE.md` (as LibRaw → CDDL-1.0).
- **LGPL / Qt-class:** ensure **dynamic** linking; add the "prominent notice"
  to both About dialogs (`App/Sources/HyperfocalAppMain.swift`,
  `QtShell/Main.qml`); and follow the packaging checklist in ROADMAP's
  **"Release & licensing compliance"** (bundle GPL+LGPL texts, host exact source
  or written offer, don't ship GPL-only build tools, provide an off-Store
  relinkable build).
- **Build wiring, everywhere it's referenced:** `Package.swift` (Windows
  `winImagingLibs` + Linux `imagingPkgs`), the vcpkg install lists in `README.md`
  **and** `.github/workflows/windows.yml`, the apt lists in `README.md`,
  `.github/workflows/ci.yml`, **and** `ROADMAP.md`. Keep them consistent — a
  half-updated dep list breaks CI or ships an un-noticed library.

## Repo map

`LICENSE` (MIT) · `NOTICE.md` (per-platform third-party notices) · `licenses/`
(bundled standard texts) · `Vendor/` and `Sources/CImaging/easyexif/` (vendored
deps) · `Package.swift` · the two CI workflows · About dialogs in
`App/Sources/HyperfocalAppMain.swift` and `QtShell/Main.qml` · ROADMAP
"Release & licensing compliance" for the outstanding packaging duties.

## Done means

License identified from its own text and judged compatible (or user-approved for
anything non-permissive); `NOTICE.md` + `licenses/` updated; build config updated
across **all** platforms/CI; mandatory verbatim notices reproduced; About updated
if it's LGPL-class — all landed together with the integration, not promised for
later.
