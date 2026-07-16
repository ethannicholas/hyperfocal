import XCTest

/// One session over the Tone panel: sliders visibly change exported pixels,
/// Reset restores them, and DNG exports stay linear with the tone riding
/// along as embedded Camera Raw XMP.
final class ToneJourneyTests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    func testToneJourney() throws {
        let app = try launchApp(stacks: ["stack-a"])
        XCTAssertTrue(app.buttons["fusion.fuse-stack"].waitForExistence(timeout: 15))
        app.buttons["fusion.fuse-stack"].click()
        waitForFuseDone(app)
        try sendCommand(["action": "set-export", "format": "TIFF (16-bit)"])

        let baseline = try exportAndInspect("tone-baseline.tif")

        let exposureValue = app.staticTexts["tone.slider.exposure.value"]

        try XCTContext.runActivity(named: "exposure brightens exported pixels") { _ in
            try setSliderValue("tone.slider.exposure", to: 2, valueText: exposureValue)
            XCTAssertEqual(text(of: exposureValue), "+2.00 EV")
            let brighter = try exportAndInspect("tone-brighter.tif")
            XCTAssertGreaterThan(brighter.meanLevel, baseline.meanLevel + 10,
                                 "+2 EV barely moved the export "
                                 + "(\(baseline.meanLevel) → \(brighter.meanLevel))")
        }

        try XCTContext.runActivity(named: "contrast changes the render too") { _ in
            try setSliderValue("tone.slider.contrast", to: 60,
                               valueText: app.staticTexts["tone.slider.contrast.value"])
            _ = try exportAndInspect("tone-contrast.tif")
            XCTAssertGreaterThan(
                try pixelDiff(Fixtures.out.appendingPathComponent("tone-brighter.tif"),
                              Fixtures.out.appendingPathComponent("tone-contrast.tif")),
                1.0, "contrast change should alter the render")
        }

        try XCTContext.runActivity(named: "Reset restores the neutral render") { _ in
            XCTAssertTrue(app.buttons["tone.reset"].waitForExistence(timeout: 5),
                          "tone Reset should appear for non-neutral settings")
            app.buttons["tone.reset"].click()
            XCTAssertEqual(text(of: exposureValue), "+0.00 EV")
            _ = try exportAndInspect("tone-reset.tif")
            XCTAssertLessThan(
                try pixelDiff(Fixtures.out.appendingPathComponent("tone-baseline.tif"),
                              Fixtures.out.appendingPathComponent("tone-reset.tif")),
                1.0, "reset render should match the baseline")
            XCTAssertTrue(waitFor { !app.buttons["tone.reset"].exists },
                          "Reset should disappear at neutral")
        }

        try XCTContext.runActivity(named: "DNG stays linear, tone rides as XMP") { _ in
            try sendCommand(["action": "set-export", "format": "DNG (raw)"])
            let neutralURL = Fixtures.out.appendingPathComponent("tone-neutral.dng")
            try sendCommand(["action": "export", "path": neutralURL.path])
            let neutralData = try Data(contentsOf: neutralURL)
            XCTAssertNil(neutralData.range(of: Data("crs:".utf8)),
                         "neutral tone must not embed Camera Raw XMP")

            try setSliderValue("tone.slider.exposure", to: 2, valueText: exposureValue)
            let tonedURL = Fixtures.out.appendingPathComponent("tone-toned.dng")
            try sendCommand(["action": "export", "path": tonedURL.path])
            let tonedData = try Data(contentsOf: tonedURL)
            XCTAssertNotNil(tonedData.range(of: Data("crs:Exposure2012".utf8)),
                            "toned DNG must carry Camera Raw XMP")
            // The pixel payload is unaffected by tone (DNG stays linear):
            // the toned file is the neutral file plus the XMP block and a
            // relocated IFD, so sizes differ by only a few KB.
            XCTAssertLessThan(abs(tonedData.count - neutralData.count), 8192,
                              "toned DNG pixels should match the neutral export")
        }
    }
}
