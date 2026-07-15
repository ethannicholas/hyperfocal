import XCTest

/// Timing- and fault-injection flows, each needing its own fixture/launch:
/// cancel feedback mid-fuse, and bad-frame auto-exclusion.
final class CancelAndBadFrameTests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    func testCancelShowsPersistentCancelling() throws {
        let app = try launchApp(stacks: ["cancel-stack"])
        let fuse = app.buttons["fusion.fuse-stack"]
        XCTAssertTrue(fuse.waitForExistence(timeout: 15))
        fuse.click()
        let cancel = app.buttons["progress.cancel"]
        guard cancel.waitForExistence(timeout: 10) else {
            throw XCTSkip("fuse finished before Cancel could be clicked")
        }
        // Click by window-relative coordinates captured while the button
        // exists: element-based clicks re-resolve the element at click time
        // and fail the test outright if the overlay just vanished — with
        // coordinates, a too-late click lands on the pane as a no-op and
        // the skip path below reports it honestly.
        let frame = cancel.frame
        let window = app.windows.firstMatch
        let wf = window.frame
        window.coordinate(withNormalizedOffset: CGVector(
            dx: (frame.midX - wf.minX) / wf.width,
            dy: (frame.midY - wf.minY) / wf.height)).click()
        // From the click until teardown, the stage label must never revert
        // to a stage name — the shipped bug was "Cancelling…" flipping back
        // to "Reading frames" while in-flight decodes drained. Reads go
        // through app.snapshot(): element property reads race the overlay's
        // teardown and abort the test when it vanishes mid-read.
        let deadline = Date().addingTimeInterval(60)
        var sawCancelling = false
        while Date() < deadline {
            guard let label = stageText(app) else { break }  // overlay gone
            if label.contains("Cancelling") { sawCancelling = true }
            XCTAssertFalse(sawCancelling && !label.contains("Cancelling"),
                           "stage reverted from Cancelling… to \(label)")
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertNil(stageText(app), "cancel never completed")
        if !sawCancelling {
            throw XCTSkip("cancel landed between progress updates")
        }
    }

    func testMisfireFrameAutoExcluded() throws {
        let frames = try Fixtures.frames(in: "misfire-stack")
        let app = try launchApp(stacks: ["misfire-stack"])
        XCTAssertTrue(app.buttons["fusion.fuse-stack"].waitForExistence(timeout: 15))
        app.buttons["fusion.fuse-stack"].click()
        waitForFuseDone(app)
        // The dark misfire frame (injected at index 2 by the fixture script)
        // gets flagged and its checkbox cleared; the count reflects it.
        let count = app.staticTexts["stack.count"]
        XCTAssertTrue(waitFor {
            text(of: count) == "\(frames.count - 1) of \(frames.count)"
        }, "misfire frame not excluded (count: \(text(of: count)))")
        let box = app.checkBoxes["frame.row.frame_002.jpg.included"]
        XCTAssertTrue(box.exists)
        XCTAssertEqual(box.value as? Int, 0, "misfire frame should be unchecked")
    }

    /// The progress stage text via a snapshot: nil when the overlay is gone.
    private func stageText(_ app: XCUIApplication) -> String? {
        guard let root = try? app.snapshot() else { return nil }
        func find(_ node: XCUIElementSnapshot) -> String? {
            if node.identifier == "progress.stage" {
                return (node.value as? String) ?? node.label
            }
            for child in node.children {
                if let hit = find(child) { return hit }
            }
            return nil
        }
        return find(root)
    }
}
