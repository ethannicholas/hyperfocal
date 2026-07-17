import XCTest

/// The freshly-launched contract: nothing loaded, nothing enabled that
/// shouldn't be.
final class EmptyStateTests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    func testEmptyState() throws {
        let app = try launchApp()
        XCTAssertTrue(app.buttons["stack.open-folder"].waitForExistence(timeout: 10))
        XCTAssertEqual(text(of: app.staticTexts["output.pane.hint"]), "No output yet")
        XCTAssertFalse(app.buttons["fusion.fuse-stack"].isEnabled)
        // Present but disabled pre-fuse (the section used to hide entirely,
        // which read as broken next to the always-visible Export section).
        XCTAssertTrue(app.buttons["retouch.start"].exists)
        XCTAssertFalse(app.buttons["retouch.start"].isEnabled)
        XCTAssertFalse(menuItemEnabled(app, menu: "File", item: "Save Project"))
        XCTAssertFalse(menuItemEnabled(app, menu: "File", item: "Save Project As…"))
        XCTAssertFalse(menuItemEnabled(app, menu: "File", item: "Close Stack"))
        XCTAssertFalse(menuItemEnabled(app, menu: "File", item: "Close Project"))
        XCTAssertFalse(menuItemEnabled(app, menu: "File", item: "Export Result…"))
    }
}
