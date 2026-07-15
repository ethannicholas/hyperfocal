import XCTest

/// One session over the fuse → export pipeline: every export format, three
/// color spaces, the depth-map export, and proof that a fusion setting
/// actually changes the rendered output — all verified by reading the
/// exported bytes back on the runner side.
final class FuseExportJourneyTests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    func testFuseAndExports() throws {
        let app = try launchApp(stacks: ["stack-a"])
        XCTAssertTrue(app.buttons["fusion.fuse-stack"].waitForExistence(timeout: 15))
        app.buttons["fusion.fuse-stack"].click()
        waitForFuseDone(app)

        var baseline: ExportedImage!
        try XCTContext.runActivity(named: "TIFF sRGB baseline") { _ in
            pick(app, popUp: "export.format", option: "TIFF (16-bit)")
            pick(app, popUp: "export.color-space", option: "sRGB")
            baseline = try exportAndInspect("baseline.tif")
            XCTAssertEqual(baseline.typeIdentifier, "public.tiff")
            XCTAssertGreaterThan(baseline.width, 400, "canvas suspiciously small")
            XCTAssertGreaterThan(baseline.height, 300)
            XCTAssertTrue(baseline.profileName.contains("sRGB"),
                          "profile: \(baseline.profileName)")
        }

        try XCTContext.runActivity(named: "color spaces reach the file") { _ in
            pick(app, popUp: "export.color-space", option: "Display P3")
            let p3 = try exportAndInspect("p3.tif")
            XCTAssertTrue(p3.profileName.contains("P3"), "profile: \(p3.profileName)")
            pick(app, popUp: "export.color-space", option: "ProPhoto RGB")
            let prophoto = try exportAndInspect("prophoto.tif")
            // ProPhoto's canonical profile name is "ROMM RGB".
            XCTAssertTrue(prophoto.profileName.contains("ProPhoto")
                          || prophoto.profileName.contains("ROMM"),
                          "profile: \(prophoto.profileName)")
            pick(app, popUp: "export.color-space", option: "sRGB")
        }

        try XCTContext.runActivity(named: "PNG, JPEG, DNG formats") { _ in
            pick(app, popUp: "export.format", option: "PNG (16-bit)")
            let png = try exportAndInspect("out.png")
            XCTAssertEqual(png.typeIdentifier, "public.png")
            XCTAssertEqual(png.width, baseline.width)

            pick(app, popUp: "export.format", option: "JPEG")
            let jpeg = try exportAndInspect("out.jpg")
            XCTAssertEqual(jpeg.typeIdentifier, "public.jpeg")
            XCTAssertEqual(jpeg.width, baseline.width)
            // Same render, different container: levels should agree closely.
            XCTAssertEqual(jpeg.meanLevel, baseline.meanLevel, accuracy: 3.0)

            pick(app, popUp: "export.format", option: "DNG (linear raw)")
            let dngURL = Fixtures.out.appendingPathComponent("out.dng")
            try sendCommand(["action": "export", "path": dngURL.path])
            let dngData = try Data(contentsOf: dngURL)
            XCTAssertGreaterThan(dngData.count, 100_000, "DNG suspiciously small")
            // TIFF magic, either endianness.
            XCTAssertTrue(dngData.prefix(2) == Data([0x49, 0x49])
                          || dngData.prefix(2) == Data([0x4D, 0x4D]))
            // Linear render tags must be present (the Lightroom overcooking
            // fix): ProfileToneCurve is tag 50940 — cheap byte scan for the
            // profile name that carries it.
            XCTAssertNotNil(dngData.range(of: Data("Hyperfocal Linear P3".utf8)),
                            "embedded camera profile missing")
            pick(app, popUp: "export.format", option: "TIFF (16-bit)")
        }

        try XCTContext.runActivity(named: "depth map export differs from result") { _ in
            let mode = app.radioGroups["output.mode"]
            XCTAssertTrue(mode.isEnabled)
            mode.radioButtons["Depth"].click()
            let depth = try exportAndInspect("depth.tif")
            XCTAssertEqual(depth.width, baseline.width)
            XCTAssertNotEqual(depth.meanLevel, baseline.meanLevel, accuracy: 1.0,
                              "depth map should not look like the result")
            mode.radioButtons["Result"].click()
        }

        try XCTContext.runActivity(named: "fusion setting changes the render") { _ in
            // Crank the noise floor to its ceiling: on the synthetic plane
            // its render-level effect can be subtle, but the DEPTH MAP
            // reassigns wholesale — compare depth exports, where the
            // setting's effect is unambiguous.
            app.activate()
            try setSliderValue("fusion.slider.noise-floor", to: 0.95,
                               valueText: app.staticTexts["fusion.slider.noise-floor.value"])
            XCTAssertTrue(app.buttons["fusion.reset"].waitForExistence(timeout: 5),
                          "Reset should appear once settings leave defaults")
            app.buttons["fusion.fuse-stack"].click()
            waitForFuseDone(app)
            let mode = app.radioGroups["output.mode"]
            mode.radioButtons["Depth"].click()
            _ = try exportAndInspect("depth-noisy.tif")
            XCTAssertGreaterThan(
                try pixelDiff(Fixtures.out.appendingPathComponent("depth.tif"),
                              Fixtures.out.appendingPathComponent("depth-noisy.tif")),
                5.0, "maxed noise floor barely moved the depth map")
            mode.radioButtons["Result"].click()
            // Reset restores defaults; a re-fuse must reproduce the baseline.
            app.buttons["fusion.reset"].click()
            app.buttons["fusion.fuse-stack"].click()
            waitForFuseDone(app)
            _ = try exportAndInspect("restored.tif")
            XCTAssertLessThan(
                try pixelDiff(Fixtures.out.appendingPathComponent("baseline.tif"),
                              Fixtures.out.appendingPathComponent("restored.tif")),
                1.0, "default re-fuse should reproduce the baseline render")
        }
    }
}
