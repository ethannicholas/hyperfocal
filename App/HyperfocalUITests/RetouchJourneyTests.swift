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
        }
    }
}
