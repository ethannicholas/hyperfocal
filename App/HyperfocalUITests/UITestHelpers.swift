import XCTest
import ImageIO
import CoreGraphics

/// Shared plumbing for the journey suites. Fixtures are synthetic stacks
/// that Scripts/ui-test.sh generates into the app's sandbox container —
/// the one place the sandboxed app can read without a panel grant. The
/// test runner can READ the container via absolute paths (verified) but
/// cannot WRITE it, so runner→app requests travel as distributed
/// notifications and app→runner results come back as container files.
enum Fixtures {
    /// The real user home. The xctrunner process runs with HOME pointed
    /// into its own container, so homeDirectoryForCurrentUser/NSHomeDirectory
    /// would silently prefix every path with the runner container; the
    /// passwd entry is immune to that redirection.
    static let realHome: URL = {
        if let dir = getpwuid(getuid())?.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }()

    /// Fixture root inside the app container — readable by both sides.
    static let root = realHome
        .appendingPathComponent("Library/Containers/com.ethannicholas.hyperfocal"
                                + "/Data/tmp/hyperfocal-uitest/fixtures")

    /// Scratch area for app-written outputs (exports, projects, command
    /// results). Same directory — the app owns it, the runner reads it.
    static let out = root.appendingPathComponent("out")

    static func stack(_ name: String) -> URL {
        root.appendingPathComponent(name)
    }

    /// Frame files of a fixture stack, name-sorted (the app's default order
    /// for undated synth frames). Stacks use distinct name prefixes so
    /// accessibility identifiers stay unique across stacks.
    static func frames(in name: String) throws -> [String] {
        let all = try FileManager.default.contentsOfDirectory(atPath: stack(name).path)
        return all.filter { $0.hasSuffix(".jpg") }.sorted()
    }

    static func requireStack(_ name: String) throws -> URL {
        let url = stack(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("fixture \(name) missing — run Scripts/ui-test.sh")
        }
        return url
    }
}

/// SwiftUI static texts on macOS expose their content as the AX *value*
/// (label is usually empty) — read both, value first.
func text(of element: XCUIElement) -> String {
    if let value = element.value as? String, !value.isEmpty { return value }
    return element.label
}

// MARK: - Image inspection (runner-side, on app-exported files)

struct ExportedImage {
    let width: Int
    let height: Int
    let typeIdentifier: String
    let profileName: String
    /// Mean of a decoded thumbnail's RGB bytes, 0–255 — coarse but plenty
    /// to detect exposure shifts and setting changes.
    let meanLevel: Double
}

/// Max per-channel absolute difference between two images' 64px thumbnails
/// (0–255). Renders are deterministic, so identical settings give ~0 and any
/// visible change clears a small threshold even when a whole-image mean
/// wouldn't move.
func pixelDiff(_ a: URL, _ b: URL) throws -> Double {
    func thumbPixels(_ url: URL) throws -> [UInt8] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 64,
              ] as CFDictionary) else {
            throw NSError(domain: "uitest", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "undecodable image at \(url.path)"])
        }
        var pixels = [UInt8](repeating: 0, count: 64 * 64 * 4)
        guard let ctx = CGContext(data: &pixels, width: 64, height: 64,
                                  bitsPerComponent: 8, bytesPerRow: 64 * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw NSError(domain: "uitest", code: 4) }
        ctx.interpolationQuality = .high
        ctx.draw(thumb, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        return pixels
    }
    let pa = try thumbPixels(a), pb = try thumbPixels(b)
    var maxDiff = 0.0
    for i in 0..<pa.count where i % 4 != 3 {  // skip alpha
        maxDiff = max(maxDiff, abs(Double(pa[i]) - Double(pb[i])))
    }
    return maxDiff
}

func inspectImage(at url: URL) throws -> ExportedImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let type = CGImageSourceGetType(source),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
              as? [CFString: Any] else {
        throw NSError(domain: "uitest", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "unreadable image at \(url.path)"])
    }
    let thumbOptions: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: 64,
    ]
    guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0,
                                                          thumbOptions as CFDictionary) else {
        throw NSError(domain: "uitest", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "undecodable image at \(url.path)"])
    }
    var sum = 0.0
    var count = 0.0
    let w = thumb.width, h = thumb.height
    var pixels = [UInt8](repeating: 0, count: w * h * 4)
    if let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                           bytesPerRow: w * 4,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!,
                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
        ctx.draw(thumb, in: CGRect(x: 0, y: 0, width: w, height: h))
        for i in stride(from: 0, to: pixels.count, by: 4) {
            sum += Double(pixels[i]) + Double(pixels[i + 1]) + Double(pixels[i + 2])
            count += 3
        }
    }
    return ExportedImage(
        width: (props[kCGImagePropertyPixelWidth] as? Int) ?? 0,
        height: (props[kCGImagePropertyPixelHeight] as? Int) ?? 0,
        typeIdentifier: type as String,
        profileName: (props[kCGImagePropertyProfileName] as? String) ?? "",
        meanLevel: count > 0 ? sum / count : 0)
}

// MARK: - XCTestCase plumbing

extension XCTestCase {

    /// Launches the app in UI-test mode. `stacks` are fixture names for
    /// HYPERFOCAL_LOAD_STACK; extra env vars merge on top.
    func launchApp(stacks: [String] = [], env: [String: String] = [:]) throws -> XCUIApplication {
        for name in stacks { _ = try Fixtures.requireStack(name) }
        let app = XCUIApplication()
        app.launchEnvironment["HYPERFOCAL_UITEST"] = "1"
        app.launchEnvironment["HYPERFOCAL_AUTOCONFIRM"] = "1"
        if !stacks.isEmpty {
            app.launchEnvironment["HYPERFOCAL_LOAD_STACK"] =
                stacks.map { Fixtures.stack($0).path }.joined(separator: ":")
        }
        for (key, value) in env { app.launchEnvironment[key] = value }
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15),
                      "app window never appeared")
        return app
    }

    /// Sends a command to the running app (see UITestSupport.swift) and
    /// waits for its result file. The app writes results into the container;
    /// the runner reads them.
    @discardableResult
    func sendCommand(_ command: [String: String],
                     timeout: TimeInterval = 60) throws -> [String: String] {
        var command = command
        let resultURL = Fixtures.out.appendingPathComponent("cmd-\(UUID().uuidString).json")
        command["result"] = resultURL.path
        let json = String(data: try JSONSerialization.data(withJSONObject: command),
                          encoding: .utf8)!
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("org.hyperfocal.uitest.command"),
            object: json, userInfo: nil, deliverImmediately: true)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: resultURL),
               let result = (try? JSONSerialization.jsonObject(with: data))
                   as? [String: String] {
                XCTAssertEqual(result["ok"], "1",
                               "command \(command["action"] ?? "?") failed: "
                               + (result["detail"] ?? ""))
                return result
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTFail("command \(command["action"] ?? "?") never answered")
        return [:]
    }

    /// Exports through the app's current format/space/tone/output-mode state
    /// and returns the inspected result.
    func exportAndInspect(_ name: String) throws -> ExportedImage {
        let url = Fixtures.out.appendingPathComponent(name)
        try sendCommand(["action": "export", "path": url.path])
        return try inspectImage(at: url)
    }

    /// Fuse completion: the progress overlay must be gone and the export
    /// button live. When `expectAligned`, also require the input pane title
    /// to carry "(aligned)" (untrue for alignment-off fuses).
    func waitForFuseDone(_ app: XCUIApplication, expectAligned: Bool = true,
                         timeout: TimeInterval = 120) {
        let title = app.staticTexts["input.pane.title"]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !app.progressIndicators["progress.bar"].exists,
               app.buttons["export.result"].exists,
               app.buttons["export.result"].isEnabled,
               !expectAligned || (title.exists && text(of: title).contains("(aligned)")) {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTFail("fuse did not complete within \(Int(timeout))s "
                + "(input title: \(title.exists ? text(of: title) : "missing"))")
    }

    /// Opens `menu` in the menu bar, returns the item's enabled state, and
    /// closes the menu again. Menu items only resolve while the menu is open.
    func menuItemEnabled(_ app: XCUIApplication, menu: String, item: String) -> Bool {
        let bar = app.menuBars.menuBarItems[menu]
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "no \(menu) menu")
        bar.click()
        let element = app.menuBars.menuItems[item]
        XCTAssertTrue(element.waitForExistence(timeout: 5), "no \(item) in \(menu)")
        let enabled = element.isEnabled
        app.typeKey(.escape, modifierFlags: [])
        return enabled
    }

    /// Clicks a menu item (asserts it is enabled first).
    func clickMenuItem(_ app: XCUIApplication, menu: String, item: String) {
        let bar = app.menuBars.menuBarItems[menu]
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "no \(menu) menu")
        bar.click()
        let element = app.menuBars.menuItems[item]
        XCTAssertTrue(element.waitForExistence(timeout: 5), "no \(item) in \(menu)")
        XCTAssertTrue(element.isEnabled, "\(item) is disabled")
        element.click()
    }

    /// Sets a slider to a normalized position, VERIFYING the change through
    /// its value text. XCUITest slider mechanics are unreliable on SwiftUI
    /// (adjust and element drags silently no-op for offscreen or
    /// focus-confused controls), so: scroll into view, try adjust, verify,
    /// fall back to a window-relative thumb drag, verify, and fail with
    /// geometry diagnostics if nothing moved.
    func setSlider(_ app: XCUIApplication, _ slider: XCUIElement,
                   valueText: XCUIElement, to position: Double) {
        XCTAssertTrue(slider.waitForExistence(timeout: 5), "slider missing")
        var attempts = 0
        while !slider.isHittable && attempts < 10 {
            let scrollView = app.scrollViews
                .containing(.slider, identifier: slider.identifier).firstMatch
            // Direction flips halfway in case the control is above the fold.
            scrollView.scroll(byDeltaX: 0, deltaY: attempts < 5 ? -80 : 80)
            attempts += 1
        }
        let before = text(of: valueText)

        slider.adjust(toNormalizedSliderPosition: position)
        if waitFor(timeout: 2, { text(of: valueText) != before }) { return }

        // Fallback: drag the thumb by raw window coordinates (proven against
        // CGEvent ground truth where adjust no-ops).
        let f = slider.frame
        let window = app.windows.firstMatch
        let wf = window.frame
        func coordinate(_ x: Double) -> XCUICoordinate {
            window.coordinate(withNormalizedOffset: CGVector(
                dx: (x - wf.minX) / wf.width,
                dy: (f.midY - wf.minY) / wf.height))
        }
        let travel = f.width - 16
        let fromX = f.minX + 8 + slider.normalizedSliderPosition * travel
        let toX = f.minX + 8 + position * travel
        coordinate(fromX).press(forDuration: 0.15, thenDragTo: coordinate(toX))
        if waitFor(timeout: 2, { text(of: valueText) != before }) { return }

        XCTFail("slider \(slider.identifier) never moved (value \(before), "
                + "frame \(f), window \(wf), hittable \(slider.isHittable))")
    }

    /// Sets a slider's bound value through the command channel (see
    /// UITestSupport: XCUITest cannot reliably move SwiftUI sliders in some
    /// window states) and verifies the UI's value label reflects it.
    func setSliderValue(_ id: String, to value: Double,
                        valueText: XCUIElement) throws {
        let before = text(of: valueText)
        try sendCommand(["action": "set-slider", "id": id, "value": String(value)])
        XCTAssertTrue(waitFor(timeout: 5) { text(of: valueText) != before },
                      "value label for \(id) never updated (still \(before))")
    }

    /// Polls a condition on the main run loop.
    func waitFor(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return condition()
    }
}
