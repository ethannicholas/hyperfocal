import XCTest

/// Shared plumbing for the smoke suite. Fixtures are synthetic stacks that
/// Scripts/ui-test.sh generates into the app's sandbox container — the one
/// place a sandboxed app can read without a panel grant — and tests seed
/// the app through the HYPERFOCAL_* launch environment (UITestSupport.swift)
/// so no NSOpenPanel/NSSavePanel is ever driven.
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

    /// Where the APP reads fixtures: inside its own sandbox container (the
    /// one place a sandboxed app reads with no panel grant). These URLs are
    /// handed to the app via launch environment; the runner reads the /tmp
    /// mirror instead.
    static let appRoot = realHome
        .appendingPathComponent("Library/Containers/com.ethannicholas.hyperfocal"
                                + "/Data/tmp/hyperfocal-uitest/fixtures")

    /// Where the RUNNER reads fixtures: an identical copy in /tmp, written
    /// by Scripts/ui-test.sh alongside the container copy.
    static let mirror = URL(fileURLWithPath: "/tmp/hyperfocal-uitest-fixtures",
                            isDirectory: true)

    /// App-side path for launch environment values.
    static func stack(_ name: String) -> URL {
        appRoot.appendingPathComponent(name)
    }

    /// Frame files of a fixture stack, name-sorted (the app's default order
    /// for undated synth frames). Read from the mirror.
    static func frames(in name: String) throws -> [String] {
        let all = try FileManager.default.contentsOfDirectory(
            atPath: mirror.appendingPathComponent(name).path)
        return all.filter { $0.hasPrefix("frame_") }.sorted()
    }

    static func requireStack(_ name: String) throws -> URL {
        guard FileManager.default.fileExists(
            atPath: mirror.appendingPathComponent(name).path) else {
            throw XCTSkip("fixture \(name) missing — run Scripts/ui-test.sh")
        }
        return stack(name)
    }
}

/// SwiftUI static texts on macOS expose their content as the AX *value*
/// (label is usually empty) — read both, value first.
func text(of element: XCUIElement) -> String {
    if let value = element.value as? String, !value.isEmpty { return value }
    return element.label
}

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

    /// The input pane title flips to "… (aligned)" when a fuse completes and
    /// the aligned decode replaces the raw one; the progress overlay leaving
    /// confirms the run fully settled.
    func waitForFuseDone(_ app: XCUIApplication, timeout: TimeInterval = 120) {
        let title = app.staticTexts["input.pane.title"]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if title.exists, text(of: title).contains("(aligned)"),
               !app.progressIndicators["progress.bar"].exists {
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
}
