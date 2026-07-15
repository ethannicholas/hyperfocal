---
name: verify
description: Build, launch, and drive the Hyperfocal app end-to-end to verify a change — window automation recipes, AX quirks, synth test fixtures, and regression gates. Use whenever a change needs to be seen working in the real app, not just compiled. Prefer probe/CLI checks where they can see the behavior; prefer asking the user for UI checks a human validates easily.
---

# Verifying Hyperfocal changes

## Choosing how to verify

- **Prefer automatic checks** for anything the command-line tools can
  observe: engine/model behavior goes through `retouch-probe` (extend
  `Probe/main.swift` if the current checks don't cover it) and
  `hyperfocal-cli` (`synth` fixtures, `compare` for image diffs). These
  are cheap, repeatable, and don't touch the screen.
- **UI-layer changes go through the XCUITest smoke suite**:
  `Scripts/ui-test.sh` (or `--only testName` for one flow) must print
  `== UI TESTS PASSED`. It generates its own synth fixtures (app container
  + /tmp mirror — the runner can't read the container because its HOME is
  redirected) and seeds the app through the `HYPERFOCAL_*` launch-env
  hooks (`UITestSupport.swift`) — never by driving open/save panels.
  Extend `App/HyperfocalUITests/` when a change adds a workflow-gating
  control; every control needs an accessibility identifier (convention in
  CLAUDE.md). The suite takes over mouse/keyboard while running — same
  announce-it etiquette as AX driving — and the first run on a machine
  needs a one-time Automation approval from the GUI session.
- **Prefer asking the user** for what the suite can't see: visual
  fidelity, hover/cursor behavior, focus/activation, drag feel, anything
  timing-dependent or "sometimes", and retouch-canvas gestures (the probe
  covers the retouch model; nothing automated covers its painting).
  Give the user a short, concrete checklist of what to look for,
  including any deliberate behavior changes they might read as bugs.

```sh
swift build                            # engine + CLI + retouch-probe
cd App && xcodegen generate            # ALWAYS after adding files to App/Sources
xcodebuild -project Hyperfocal.xcodeproj -scheme Hyperfocal \
    -configuration Debug -destination 'platform=macOS' build
```

Real signing works from the CLI (team Y3GFBT2WQ2); no ad-hoc workarounds
needed. Product lands in
`~/Library/Developer/Xcode/DerivedData/Hyperfocal-*/Build/Products/Debug/`.

**Gotcha:** XcodeGen generates `App/Info.plist` and the `.xcodeproj` from
`App/project.yml` — hand-edits to either are silently reverted. Change
`project.yml`. A `.metal` file added without regenerating simply doesn't
ship (no `default.metallib` → SwiftUI shaders silently no-op).

## Regression gates (run before trusting any engine/model change)

```sh
.build/debug/hyperfocal-cli synth -o /tmp/synth --frames 15 --max-blur 6 --breathing 0.02 --jitter 3
.build/debug/retouch-probe /tmp/synth/frame_*.tif    # must print "probe: ALL PASS"
```

Synth PSNR baselines (default params): plane ≈ 38.6 dB dmap / 37.5 pmax;
object ≈ 39.2 unslabbed / 38.4 slabbed; CPU↔GPU parity ≥ 90 dB.

## Test fixtures

`hyperfocal-cli synth` makes stacks to order: `--scene object` (subject on
dark background — photogenic), `--ext jpg` (small), `--width/--height`
(size the coordinate math you're probing), `--misfire-frame` (bad-frame
handling). Move `ground_truth.*` out of the folder before loading it in
the app or it ingests as a frame.

## Driving the app (System Events / AX)

Mostly superseded by the XCUITest suite for anything it covers — controls
now carry accessibility identifiers (`value of attribute "AXIdentifier"`),
so when ad-hoc driving IS needed, find elements by identifier instead of
frame math. The notes below remain for flows outside the suite.

- **Etiquette first**: the user is often at the machine. Announce app
  launches in chat, quit instances when done, and if clicks start landing
  in other apps' windows, STOP and ask them to test by hand instead of
  fighting for the screen. They may also quit app instances they notice —
  a vanished process is not necessarily a crash (check
  `~/Library/Logs/DiagnosticReports/` before diagnosing).
- Open panels are reliable: `keystroke "n" using command down`, then
  ⌘⇧G, type the path, Return, Return.
- Buttons: get the AX element's position/size and `click at` its center.
  Frames move as neighboring labels change width (the zoom −/+ buttons
  shift when the percent label changes) — re-locate after every action
  that changes layout. `perform action "AXPress"` works on buttons found
  by name (most Hyperfocal buttons are anonymous; find by frame).
- Sliders: AXValue writes fail; `perform action "AXIncrement"` steps by
  range/10. Verify the value after, don't assume.
- Section headers and stack rows are real buttons now (AXPress works;
  headers report collapsed/expanded via AXValue). The old "onTapGesture
  headers ignore synthetic clicks" problem is fixed — and the invariant
  in CLAUDE.md forbids reintroducing gesture-only tappables.
- The Save panel is a modal window named "Save" (not a sheet) and its AX
  tree is flaky; the Replace confirmation is `sheet 1 of window "Save"`.
  For persistence checks, extend the probe's project round-trip instead.
- Retouch mode eats letter keys as brush shortcuts (p/r/space/arrows) —
  never type blind while a retouch session is active.
- Fusion completion: poll the input pane title for "(aligned)".
- Mouse drags (pan/paint) need CGEvents — AppleScript can't; compile a
  small Swift tool posting leftMouseDown/Dragged/Up.

## Seeing results

- `screencapture -x -R<x>,<y>,<w>,<h>` after bringing the app frontmost
  (a covered window captures whatever's on top of it).
- Quantitative display comparisons: crop the same pane region twice and
  run `hyperfocal-cli compare a.png b.png` — >30 dB PSNR ≈ identical
  modulo antialiasing; the ~5–20 dB range means visibly different.
- Preview↔export parity: export a TIFF, load it back as a new stack, and
  compare its pane against the original's toned pane.
