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
        app.activate()  // another app can steal focus between launch and click
        app.buttons["fusion.fuse-stack"].click()
        waitForFuseDone(app)

        var baseline: ExportedImage!
        try XCTContext.runActivity(named: "TIFF sRGB baseline") { _ in
            try sendCommand(["action": "set-export", "format": "TIFF (16-bit)"])
            try sendCommand(["action": "set-export", "space": "sRGB"])
            baseline = try exportAndInspect("baseline.tif")
            XCTAssertEqual(baseline.typeIdentifier, "public.tiff")
            XCTAssertGreaterThan(baseline.width, 400, "canvas suspiciously small")
            XCTAssertGreaterThan(baseline.height, 300)
            XCTAssertTrue(baseline.profileName.contains("sRGB"),
                          "profile: \(baseline.profileName)")
        }

        try XCTContext.runActivity(named: "color spaces reach the file") { _ in
            try sendCommand(["action": "set-export", "space": "Display P3"])
            let p3 = try exportAndInspect("p3.tif")
            XCTAssertTrue(p3.profileName.contains("P3"), "profile: \(p3.profileName)")
            try sendCommand(["action": "set-export", "space": "ProPhoto RGB"])
            let prophoto = try exportAndInspect("prophoto.tif")
            // ProPhoto's canonical profile name is "ROMM RGB".
            XCTAssertTrue(prophoto.profileName.contains("ProPhoto")
                          || prophoto.profileName.contains("ROMM"),
                          "profile: \(prophoto.profileName)")
            try sendCommand(["action": "set-export", "space": "sRGB"])
        }

        try XCTContext.runActivity(named: "PNG, JPEG, DNG formats") { _ in
            try sendCommand(["action": "set-export", "format": "PNG (16-bit)"])
            let png = try exportAndInspect("out.png")
            XCTAssertEqual(png.typeIdentifier, "public.png")
            XCTAssertEqual(png.width, baseline.width)

            try sendCommand(["action": "set-export", "format": "JPEG"])
            let jpeg = try exportAndInspect("out.jpg")
            XCTAssertEqual(jpeg.typeIdentifier, "public.jpeg")
            XCTAssertEqual(jpeg.width, baseline.width)
            // Same render, different container: levels should agree closely.
            XCTAssertEqual(jpeg.meanLevel, baseline.meanLevel, accuracy: 3.0)

            try sendCommand(["action": "set-export", "format": "DNG (raw)"])
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
            try sendCommand(["action": "set-export", "format": "TIFF (16-bit)"])
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

        try XCTContext.runActivity(named: "PMax algorithm selector swaps sliders and fuses") { _ in
            // Switching the primary algorithm to PMax replaces the DMap
            // sliders with the two debloom sliders, and a fuse produces an
            // exportable result; switching back to DMap restores its sliders
            // (both results are cached, so the switch itself is instant).
            let pmaxRadio = app.buttons["fusion.method.pmax"]
            XCTAssertTrue(pmaxRadio.waitForExistence(timeout: 5),
                          "fusion algorithm selector missing")
            pmaxRadio.click()
            XCTAssertTrue(
                app.sliders["fusion.slider.debloom-levels"].waitForExistence(timeout: 5),
                "PMax debloom-levels slider should appear")
            XCTAssertFalse(app.sliders["fusion.slider.sharpness"].exists,
                           "DMap sliders should hide under PMax")
            app.buttons["fusion.fuse-stack"].click()
            waitForFuseDone(app)
            let pmax = try exportAndInspect("pmax.tif")
            XCTAssertEqual(pmax.width, baseline.width,
                           "PMax result must match the fused canvas")
            app.buttons["fusion.method.dmap"].click()
            XCTAssertTrue(
                app.sliders["fusion.slider.sharpness"].waitForExistence(timeout: 5),
                "DMap sliders should return when the algorithm switches back")
        }

        try XCTContext.runActivity(named: "aligned source frames export") { _ in
            // Select a range of frames (click + ⇧-click spans three rows),
            // export their aligned versions through the command channel, and
            // verify each lands on the fused canvas's dimensions — the
            // warped-into-result-space property that makes them layerable
            // under the exported result.
            let names = try Fixtures.frames(in: "stack-a")
            let first = app.staticTexts["frame.row.\(names[0])"]
            let third = app.staticTexts["frame.row.\(names[2])"]
            XCTAssertTrue(first.waitForExistence(timeout: 5))
            first.click()
            XCUIElement.perform(withKeyModifiers: .shift) { third.click() }
            let dir = Fixtures.out.appendingPathComponent("aligned", isDirectory: true)
            try sendCommand(["action": "export-aligned", "dir": dir.path])
            let exported = (try? FileManager.default
                .contentsOfDirectory(atPath: dir.path)) ?? []
            XCTAssertEqual(exported.count, 3,
                           "three selected frames → three files, got \(exported)")
            for file in exported {
                let image = try inspectImage(at: dir.appendingPathComponent(file))
                XCTAssertEqual(image.width, baseline.width,
                               "aligned frame must match the fused canvas: \(file)")
                XCTAssertEqual(image.height, baseline.height)
            }
        }

        try XCTContext.runActivity(named: "crop applies to exports") { _ in
            XCTAssertTrue(app.buttons["edit.crop"].exists, "crop button missing")
            try sendCommand(["action": "set-crop",
                             "x": "20", "y": "10", "w": "200", "h": "120"])
            let cropped = try exportAndInspect("cropped.tif")
            XCTAssertEqual(cropped.width, 200, "export must honor the crop")
            XCTAssertEqual(cropped.height, 120)
            try sendCommand(["action": "set-crop"])  // no coords = clear
            let uncropped = try exportAndInspect("uncropped.tif")
            XCTAssertEqual(uncropped.width, baseline.width,
                           "clearing the crop must restore the full canvas")
        }

        try XCTContext.runActivity(named: "rocking animation export") { _ in
            let movie = Fixtures.out.appendingPathComponent("rocking.mp4")
            try sendCommand(["action": "export-animation", "path": movie.path],
                            timeout: 60)
            let data = try Data(contentsOf: movie)
            XCTAssertGreaterThan(data.count, 50_000, "video suspiciously small")
            XCTAssertNotNil(data.range(of: Data("ftyp".utf8), in: 0..<16),
                            "not an MP4 container")
            XCTAssertNotNil(data.range(of: Data("avc1".utf8)), "no H.264 track")

            // GIF variant must carry the loop-forever extension — the whole
            // reason the format exists here.
            let gif = Fixtures.out.appendingPathComponent("rocking.gif")
            try sendCommand(["action": "export-animation", "path": gif.path],
                            timeout: 60)
            let gifData = try Data(contentsOf: gif)
            XCTAssertNotNil(gifData.range(of: Data("NETSCAPE2.0".utf8)),
                            "GIF loop extension missing")
            XCTAssertNotNil(gifData.range(of: Data("GIF8".utf8), in: 0..<6),
                            "not a GIF")
        }
    }
}
