import XCTest

/// One session over the Settings window: the toggles exist, and turning
/// alignment off demonstrably reaches the pipeline (the input pane never
/// gains "(aligned)" on an unaligned fuse).
final class SettingsJourneyTests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    func testAlignmentToggleReachesPipeline() throws {
        let app = try launchApp(stacks: ["stack-a"])
        XCTAssertTrue(app.buttons["fusion.fuse-stack"].waitForExistence(timeout: 15))

        XCTContext.runActivity(named: "settings window: toggles present") { _ in
            // Via the app menu: ⌘, keystrokes are swallowed when focus is
            // still settling after launch; the menu item is deterministic.
            clickMenuItem(app, menu: "Hyperfocal", item: "Settings…")
            // Scope queries to the settings window — auxiliary windows
            // don't always surface in app-wide element shorthands.
            let settings = app.windows["Hyperfocal Settings"]
            XCTAssertTrue(settings.waitForExistence(timeout: 10),
                          "settings window never opened")
            // Any-type descendant queries: the toggles' element type varies
            // (checkbox vs switch) across macOS/SwiftUI versions.
            func toggle(_ id: String) -> XCUIElement {
                settings.descendants(matching: .any)[id]
            }
            let align = toggle("settings.align")
            XCTAssertTrue(align.waitForExistence(timeout: 5))
            XCTAssertTrue(toggle("settings.order-by-capture").exists)
            XCTAssertTrue(toggle("settings.normalize-exposure").exists)
            XCTAssertTrue(toggle("settings.slab").exists)
            XCTAssertTrue(toggle("settings.gpu").exists)
            XCTAssertEqual(align.value as? Int, 1, "alignment should default on")
            align.click()
            XCTAssertTrue(waitFor { (align.value as? Int) == 0 },
                          "alignment toggle never flipped")
            app.typeKey("w", modifierFlags: .command)  // close settings window
        }

        XCTContext.runActivity(named: "unaligned fuse: no (aligned) title") { _ in
            app.buttons["fusion.fuse-stack"].click()
            waitForFuseDone(app, expectAligned: false)
            let title = app.staticTexts["input.pane.title"]
            XCTAssertTrue(title.exists)
            XCTAssertFalse(text(of: title).contains("(aligned)"),
                           "alignment off must skip registration: \(text(of: title))")
        }
    }
}
