import XCTest

/// The red close button on a single-window app is a quit — and the
/// unsaved-work question must be answered BEFORE the window disappears.
/// Shipped bug: the window closed first, the quit confirmation came after
/// (twice), and Cancel had nothing left to cancel back to.
final class WindowCloseTests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func closeWindow(_ app: XCUIApplication) {
        let close = app.windows.firstMatch
            .buttons[XCUIIdentifierCloseWindow]
        XCTAssertTrue(close.waitForExistence(timeout: 5), "no close button")
        close.click()
    }

    func testCloseQuitsWhenNothingUnsaved() throws {
        let app = try launchApp(stacks: ["stack-a"])
        XCTAssertTrue(app.staticTexts["stack.count"].waitForExistence(timeout: 15))
        // Unfused project = nothing unsaved worth guarding: close quits
        // silently.
        closeWindow(app)
        XCTAssertTrue(waitFor(timeout: 15) { app.state == .notRunning },
                      "close should quit a clean app")
    }

    func testCloseCancelKeepsWindowAndApp() throws {
        // Deny-mode answers the quit confirmation with Cancel: the window
        // must survive (the shipped bug closed it regardless).
        let app = try launchApp(stacks: ["stack-a"],
                                env: ["HYPERFOCAL_CONFIRM": "deny"])
        XCTAssertTrue(app.buttons["fusion.fuse-stack"].waitForExistence(timeout: 15))
        app.buttons["fusion.fuse-stack"].click()
        waitForFuseDone(app)  // fused + unsaved = the guarded state
        closeWindow(app)
        // Give a would-be close/terminate time to happen, then assert it didn't.
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        XCTAssertEqual(app.state, .runningForeground, "cancel must not quit")
        XCTAssertTrue(app.windows.firstMatch.exists, "cancel must keep the window")
        XCTAssertTrue(app.buttons["fusion.fuse-stack"].exists,
                      "window content should be intact after cancel")
    }

    func testCloseConfirmQuitsWithUnsavedWork() throws {
        let app = try launchApp(stacks: ["stack-a"])  // AUTOCONFIRM answers Quit
        XCTAssertTrue(app.buttons["fusion.fuse-stack"].waitForExistence(timeout: 15))
        app.buttons["fusion.fuse-stack"].click()
        waitForFuseDone(app)
        closeWindow(app)
        XCTAssertTrue(waitFor(timeout: 15) { app.state == .notRunning },
                      "confirmed close should quit exactly once")
    }
}
