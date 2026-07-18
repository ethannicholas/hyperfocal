import XCTest

/// One session over the retouch workflow: enter, paint a real stroke with
/// synthesized mouse events, verify the edit registered (and reaches
/// exports), erase-mode switch, revert, and exit.
final class RetouchJourneyTests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    func testRetouchJourney() throws {
        let app = try launchApp(stacks: ["stack-a"])
        XCTAssertTrue(app.buttons["fusion.fuse-stack"].waitForExistence(timeout: 15))
        app.buttons["fusion.fuse-stack"].click()
        waitForFuseDone(app)
        try sendCommand(["action": "set-export", "format": "TIFF (16-bit)"])
        let baseline = try exportAndInspect("retouch-baseline.tif")
        try XCTContext.runActivity(named: "depth baseline for the revert check") { _ in
            let mode = app.radioGroups["output.mode"]
            mode.radioButtons["Depth"].click()
            _ = try exportAndInspect("retouch-depth-baseline.tif")
            mode.radioButtons["Result"].click()
        }

        XCTContext.runActivity(named: "enter retouch: controls appear") { _ in
            app.buttons["retouch.start"].click()
            XCTAssertTrue(app.buttons["retouch.done"].waitForExistence(timeout: 15))
            XCTAssertTrue(app.sliders["retouch.slider.brush-size"].exists)
            XCTAssertTrue(app.sliders["retouch.slider.softness"].exists)
            XCTAssertTrue(app.radioGroups["retouch.source-kind"].exists)
            XCTAssertFalse(app.buttons["retouch.revert-all"].isEnabled,
                           "Revert All enabled before any edit")
        }

        XCTContext.runActivity(named: "brush slider updates its label") { _ in
            // setSlider verifies the value text moved — that IS the test.
            setSlider(app, app.sliders["retouch.slider.brush-size"],
                      valueText: app.staticTexts["retouch.slider.brush-size.value"],
                      to: 0.35)
        }

        XCTContext.runActivity(named: "paint a stroke: the edit registers") { _ in
            // The retouched-output pane is the right half of the preview
            // area; drag across its middle. The source must be loaded before
            // strokes paint — poll Revert All as the ground truth for
            // "a stroke landed" and retry while the source decodes.
            app.activate()  // clicks stray if another app stole focus
            let window = app.windows.firstMatch
            let revert = app.buttons["retouch.revert-all"]
            var attempts = 0
            while !revert.isEnabled && attempts < 10 {
                let start = window.coordinate(withNormalizedOffset:
                    CGVector(dx: 0.75, dy: 0.45 + 0.01 * Double(attempts)))
                let end = window.coordinate(withNormalizedOffset:
                    CGVector(dx: 0.88, dy: 0.55))
                start.click(forDuration: 0.2, thenDragTo: end)
                _ = waitFor(timeout: 2) { revert.isEnabled }
                attempts += 1
            }
            XCTAssertTrue(revert.isEnabled,
                          "no stroke registered after \(attempts) attempts")
        }

        try XCTContext.runActivity(named: "the edit reaches exports") { _ in
            _ = try exportAndInspect("retouch-edited.tif")
            XCTAssertGreaterThan(
                try pixelDiff(Fixtures.out.appendingPathComponent("retouch-baseline.tif"),
                              Fixtures.out.appendingPathComponent("retouch-edited.tif")),
                1.0, "painted export should differ from the baseline")
        }

        try XCTContext.runActivity(named: "Result/Depth toggle lives in retouch too") { _ in
            // Strokes co-paint the depth plane, so the toggle stays: the
            // depth view is how animation-breaking depth artifacts get
            // found and fixed. Exporting depth mid-session exercises the
            // live session→model depth merge; the exact painted-depth
            // values are the probe's territory.
            let mode = app.radioGroups["output.mode"]
            XCTAssertTrue(mode.exists, "Result/Depth toggle gone in retouch mode")
            mode.radioButtons["Depth"].click()
            _ = try exportAndInspect("retouch-depth-edited.tif")
            mode.radioButtons["Result"].click()
        }

        XCTContext.runActivity(named: "PMax build offers Cancel; cancel falls back") { _ in
            app.radioGroups["retouch.source-kind"].radioButtons["PMax Result"].click()
            let cancel = app.buttons["retouch.pmax-cancel"]
            if cancel.waitForExistence(timeout: 2) {
                cancel.click()
                let frameRadio = app.radioGroups["retouch.source-kind"]
                    .radioButtons["Source Image"]
                XCTAssertTrue(waitFor { (frameRadio.value as? Int) == 1 },
                              "cancel should fall back to the frame source")
            }
            // A tiny fixture stack can finish the build before the button is
            // clickable — the deterministic cancel semantics are the probe's
            // territory ("pmax build cancel OK"); this smokes the control.
            // Land on the frame source either way for the steps below.
            app.radioGroups["retouch.source-kind"].radioButtons["Source Image"].click()
        }

        XCTContext.runActivity(named: "eraser mode selectable") { _ in
            app.radioGroups["retouch.source-kind"]
                .radioButtons["Original Result (erase)"].click()
            // Selection is enough here: painting-back correctness is the
            // probe's territory (RetouchSession model checks).
        }

        XCTContext.runActivity(named: "revert all, then done") { _ in
            // Retry loop: if another app floats above us, macOS spends the
            // first click on activation and the button never fires.
            let revert = app.buttons["retouch.revert-all"]
            var clicks = 0
            while revert.isEnabled && clicks < 4 {
                app.activate()
                revert.click()
                _ = waitFor(timeout: 2) { !revert.isEnabled }
                clicks += 1
            }
            XCTAssertFalse(revert.isEnabled,
                           "Revert All should disable once edits are gone")
            app.buttons["retouch.done"].click()
            XCTAssertTrue(app.buttons["retouch.start"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.radioGroups["output.mode"].exists,
                          "fusion panes should return after Done")
        }

        try XCTContext.runActivity(named: "reverted render matches baseline") { _ in
            _ = try exportAndInspect("retouch-reverted.tif")
            XCTAssertLessThan(
                try pixelDiff(Fixtures.out.appendingPathComponent("retouch-baseline.tif"),
                              Fixtures.out.appendingPathComponent("retouch-reverted.tif")),
                1.0, "reverted render should match the baseline")
            // Revert restores the co-painted depth plane exactly too.
            let mode = app.radioGroups["output.mode"]
            mode.radioButtons["Depth"].click()
            _ = try exportAndInspect("retouch-depth-reverted.tif")
            XCTAssertLessThan(
                try pixelDiff(Fixtures.out.appendingPathComponent("retouch-depth-baseline.tif"),
                              Fixtures.out.appendingPathComponent("retouch-depth-reverted.tif")),
                1.0, "reverted depth should match the fusion's")
            mode.radioButtons["Result"].click()
        }

        // Crop-then-retouch: the retouch panes must present the crop (not
        // the whole canvas) with strokes still landing under the brush. The
        // crop is the top-left quadrant, so a stroke dragged across the
        // pane's CENTER lands inside the crop only if the pane shows crop
        // space — under the old full-canvas presentation the same drag
        // painted the canvas center, outside the crop, and the cropped
        // export wouldn't change.
        try cropRetouchStep(app, name: "axis-aligned", angle: nil)
        try cropRetouchStep(app, name: "rotated", angle: 12)
        try sendCommand(["action": "set-crop"])  // clear for whoever runs next
    }

    /// Set a top-left-quadrant crop (optionally rotated), retouch a stroke
    /// through the pane center, and verify the cropped DEPTH export changed.
    /// Depth, not the result image: strokes co-paint the source's frame
    /// index into the depth plane, so after cycling the source a couple of
    /// frames the stamp differs from the fused depth no matter what the
    /// pixels look like — the result image can legitimately not change
    /// when the stamped frame is sharp exactly where the stroke lands.
    /// The crop is positioned so a pane-center stroke lands inside it only
    /// when the panes present crop space (full-canvas center falls outside).
    private func cropRetouchStep(_ app: XCUIApplication, name: String,
                                 angle: Double?) throws {
        try XCTContext.runActivity(named: "crop-then-retouch (\(name))") { _ in
            var crop = ["action": "set-crop",
                        "x": "0", "y": "0", "w": "220", "h": "160"]
            if let angle { crop["angle"] = String(angle) }
            try sendCommand(crop)
            let mode = app.radioGroups["output.mode"]
            mode.radioButtons["Depth"].click()
            let base = try exportAndInspect("crop-\(name)-depth-base.tif")
            XCTAssertEqual(base.width, 220, "export should have the crop's width")
            XCTAssertEqual(base.height, 160, "export should have the crop's height")

            app.buttons["retouch.start"].click()
            XCTAssertTrue(app.buttons["retouch.done"].waitForExistence(timeout: 15))
            app.activate()
            let window = app.windows.firstMatch
            let revert = app.buttons["retouch.revert-all"]
            var attempts = 0
            while !revert.isEnabled && attempts < 10 {
                let start = window.coordinate(withNormalizedOffset:
                    CGVector(dx: 0.75, dy: 0.45 + 0.01 * Double(attempts)))
                let end = window.coordinate(withNormalizedOffset:
                    CGVector(dx: 0.85, dy: 0.55))
                start.click(forDuration: 0.2, thenDragTo: end)
                _ = waitFor(timeout: 2) { revert.isEnabled }
                attempts += 1
            }
            XCTAssertTrue(revert.isEnabled,
                          "no stroke registered after \(attempts) attempts")

            // Move the source off whatever frame matches the local depth
            // (the first stroke focused the event view, so arrows cycle),
            // then stroke again and require the depth stamp to show up in
            // the cropped export. Retry: the cycled source loads async and
            // strokes are no-ops until it lands.
            app.typeKey(.downArrow, modifierFlags: [])
            app.typeKey(.downArrow, modifierFlags: [])
            var depthMoved = false
            for attempt in 0..<5 where !depthMoved {
                let start = window.coordinate(withNormalizedOffset:
                    CGVector(dx: 0.76, dy: 0.42 + 0.01 * Double(attempt)))
                let end = window.coordinate(withNormalizedOffset:
                    CGVector(dx: 0.88, dy: 0.58))
                start.click(forDuration: 0.2, thenDragTo: end)
                let edited = try exportAndInspect("crop-\(name)-depth-edited.tif")
                XCTAssertEqual(edited.width, 220)
                XCTAssertEqual(edited.height, 160)
                depthMoved = try pixelDiff(
                    Fixtures.out.appendingPathComponent("crop-\(name)-depth-base.tif"),
                    Fixtures.out.appendingPathComponent("crop-\(name)-depth-edited.tif")) > 1.0
            }
            XCTAssertTrue(depthMoved,
                          "a pane-center stroke should change the cropped depth export "
                          + "— it lands outside the crop if the panes show full canvas")

            // Clean up for the next step: revert the strokes, leave retouch.
            var clicks = 0
            while revert.isEnabled && clicks < 4 {
                app.activate()
                revert.click()
                _ = waitFor(timeout: 2) { !revert.isEnabled }
                clicks += 1
            }
            XCTAssertFalse(revert.isEnabled, "revert failed in crop step")
            mode.radioButtons["Result"].click()
            app.buttons["retouch.done"].click()
            XCTAssertTrue(app.buttons["retouch.start"].waitForExistence(timeout: 10))
        }
    }
}
