import XCTest

/// Smoke suite: the workflows a release must not break, prioritizing bugs
/// that actually shipped (Save gating, close flows, cancel feedback). Runs
/// serially — one window, one shared model. Fixture stacks come from
/// Scripts/ui-test.sh; every test XCTSkips with instructions if they're
/// missing.
final class HyperfocalUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: - Empty state

    func testEmptyState() throws {
        let app = try launchApp()
        XCTAssertTrue(app.buttons["stack.open-folder"].waitForExistence(timeout: 10))
        XCTAssertEqual(text(of: app.staticTexts["output.pane.hint"]), "No output yet")
        XCTAssertFalse(app.buttons["fusion.fuse-stack"].isEnabled)
        XCTAssertFalse(menuItemEnabled(app, menu: "File", item: "Save Project…"))
        XCTAssertFalse(menuItemEnabled(app, menu: "File", item: "Close Stack"))
        XCTAssertFalse(menuItemEnabled(app, menu: "File", item: "Close Project"))
    }

    // MARK: - Loading

    func testLoadStackViaEnv() throws {
        let frames = try Fixtures.frames(in: "stack-a")
        let app = try launchApp(stacks: ["stack-a"])
        let count = app.staticTexts["stack.count"]
        XCTAssertTrue(count.waitForExistence(timeout: 15))
        XCTAssertEqual(text(of: count), "\(frames.count) of \(frames.count)")
        XCTAssertTrue(app.staticTexts["frame.row.\(frames[0])"].exists)
        XCTAssertTrue(app.buttons["fusion.fuse-stack"].isEnabled)
        XCTAssertEqual(text(of: app.staticTexts["output.pane.hint"]), "Press Fuse Stack")
    }

    // MARK: - Save gating (shipped regressions)

    func testSaveEnabledForUnfusedProject() throws {
        let app = try launchApp(stacks: ["stack-a"])
        XCTAssertTrue(app.staticTexts["stack.count"].waitForExistence(timeout: 15))
        XCTAssertTrue(menuItemEnabled(app, menu: "File", item: "Save Project…"),
                      "Save must be enabled for an unfused project")
    }

    func testSaveEnabledWithUnfusedStackSelected() throws {
        let app = try launchApp(stacks: ["stack-a", "stack-b"])
        XCTAssertTrue(app.buttons["fusion.fuse-stack"].waitForExistence(timeout: 15))
        app.buttons["fusion.fuse-stack"].click()
        waitForFuseDone(app)
        let rowB = app.buttons["stack.row.stack-b"]
        XCTAssertTrue(rowB.waitForExistence(timeout: 10))
        rowB.click()
        XCTAssertTrue(rowB.isSelected, "clicking a stack row must select it")
        XCTAssertTrue(menuItemEnabled(app, menu: "File", item: "Save Project…"),
                      "Save must stay enabled with an unfused stack selected")
    }

    // MARK: - Fuse

    func testFuseEndToEnd() throws {
        let app = try launchApp(stacks: ["stack-a"])
        let fuse = app.buttons["fusion.fuse-stack"]
        XCTAssertTrue(fuse.waitForExistence(timeout: 15))
        fuse.click()
        // The overlay is legitimate to miss: a 7-frame 500×400 fuse can
        // finish inside XCUITest's first snapshot. The cancel test owns
        // overlay coverage; here it's opportunistic.
        _ = app.progressIndicators["progress.bar"].waitForExistence(timeout: 2)
        waitForFuseDone(app)
        XCTAssertTrue(app.buttons["export.result"].isEnabled)
        XCTAssertTrue(app.buttons["retouch.start"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.radioGroups["output.mode"].isEnabled)
        XCTAssertTrue(menuItemEnabled(app, menu: "File", item: "Save Project…"))
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

    // MARK: - Sidebar behaviors

    func testSectionCollapseExpand() throws {
        let app = try launchApp(stacks: ["stack-a"])
        let header = app.buttons["section.fusion"]
        let fuse = app.buttons["fusion.fuse-stack"]
        XCTAssertTrue(fuse.waitForExistence(timeout: 15))
        XCTAssertEqual(header.value as? String, "expanded")
        header.click()
        XCTAssertTrue(waitFor { !fuse.exists }, "fusion controls still visible")
        XCTAssertEqual(header.value as? String, "collapsed")
        header.click()
        XCTAssertTrue(fuse.waitForExistence(timeout: 5))
        XCTAssertEqual(header.value as? String, "expanded")
    }

    func testSliderValueLabelUpdates() throws {
        let app = try launchApp(stacks: ["stack-a"])
        let slider = app.sliders["fusion.slider.sharpness"]
        let value = app.staticTexts["fusion.slider.sharpness.value"]
        XCTAssertTrue(slider.waitForExistence(timeout: 15))
        let before = text(of: value)
        slider.adjust(toNormalizedSliderPosition: 0.9)
        if text(of: value) == before {
            // macOS slider adjustment is spotty; nudge by keyboard instead.
            slider.click()
            for _ in 0..<5 { app.typeKey(.rightArrow, modifierFlags: []) }
        }
        XCTAssertNotEqual(text(of: value), before, "slider value label never changed")
        XCTAssertTrue(text(of: value).hasSuffix(" px"))
        XCTAssertTrue(app.buttons["fusion.reset"].waitForExistence(timeout: 5),
                      "Reset should appear once settings leave defaults")
    }

    func testIncludeAllNoneAndCount() throws {
        let frames = try Fixtures.frames(in: "stack-a")
        let app = try launchApp(stacks: ["stack-a"])
        let count = app.staticTexts["stack.count"]
        XCTAssertTrue(count.waitForExistence(timeout: 15))
        app.buttons["stack.include-none"].click()
        XCTAssertTrue(waitFor { text(of: count) == "0 of \(frames.count)" },
                      "count after None: \(text(of: count))")
        XCTAssertFalse(app.buttons["fusion.fuse-stack"].isEnabled)
        app.buttons["stack.include-all"].click()
        XCTAssertTrue(waitFor { text(of: count) == "\(frames.count) of \(frames.count)" })
        XCTAssertTrue(app.buttons["fusion.fuse-stack"].isEnabled)
    }

    func testFrameCheckboxToggle() throws {
        let frames = try Fixtures.frames(in: "stack-a")
        let app = try launchApp(stacks: ["stack-a"])
        let count = app.staticTexts["stack.count"]
        XCTAssertTrue(count.waitForExistence(timeout: 15))
        let box = app.checkBoxes["frame.row.\(frames[0]).included"]
        XCTAssertTrue(box.exists)
        box.click()
        XCTAssertTrue(waitFor { text(of: count) == "\(frames.count - 1) of \(frames.count)" })
        box.click()
        XCTAssertTrue(waitFor { text(of: count) == "\(frames.count) of \(frames.count)" })
    }

    // MARK: - Close flows

    func testCloseStackAndProject() throws {
        let app = try launchApp(stacks: ["stack-a", "stack-b"])
        let rowA = app.buttons["stack.row.stack-a"]
        XCTAssertTrue(rowA.waitForExistence(timeout: 15))
        clickMenuItem(app, menu: "File", item: "Close Stack")
        // One stack left: the tree flattens to plain frame rows.
        XCTAssertTrue(waitFor { !rowA.exists && !app.buttons["stack.row.stack-b"].exists },
                      "stack rows should flatten after closing down to one stack")
        XCTAssertTrue(app.staticTexts["stack.count"].exists)
        clickMenuItem(app, menu: "File", item: "Close Project")
        XCTAssertTrue(app.buttons["stack.open-folder"].waitForExistence(timeout: 10),
                      "empty state should return after Close Project")
    }

    // MARK: - Project round trip

    func testProjectSaveOpenRoundTrip() throws {
        // Lives in the app's container: the app can write it there, and the
        // runner couldn't poll it anywhere (container protection) — launch 2
        // failing to open is the real existence assertion. Scripts/ui-test.sh
        // clears the fixtures dir every run, so no stale file survives.
        let project = Fixtures.appRoot.appendingPathComponent("roundtrip.hyperfocal")

        let first = try launchApp(stacks: ["stack-a"],
                                  env: ["HYPERFOCAL_SAVE_PROJECT": project.path])
        let fuse = first.buttons["fusion.fuse-stack"]
        XCTAssertTrue(fuse.waitForExistence(timeout: 15))
        fuse.click()
        waitForFuseDone(first)
        // UITestSupport writes the project synchronously when phase flips to
        // .done; by the time the UI settles the write is done or imminent —
        // a short grace covers the (small) zip write.
        RunLoop.current.run(until: Date().addingTimeInterval(5))
        first.terminate()

        let frames = try Fixtures.frames(in: "stack-a")
        let second = try launchApp(env: ["HYPERFOCAL_OPEN_PROJECT": project.path])
        let count = second.staticTexts["stack.count"]
        XCTAssertTrue(count.waitForExistence(timeout: 30), "project did not open")
        XCTAssertEqual(text(of: count), "\(frames.count) of \(frames.count)")
        XCTAssertTrue(second.staticTexts["frame.row.\(frames[0])"].exists)
        XCTAssertTrue(text(of: second.staticTexts["input.pane.title"]).contains("(aligned)"),
                      "restored project should decode frames (bookmarks)")
    }

    // MARK: - Zoom

    func testZoomControls() throws {
        let app = try launchApp(stacks: ["stack-a"])
        XCTAssertTrue(app.staticTexts["stack.count"].waitForExistence(timeout: 15))
        let menu = app.menuButtons["zoom.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        XCTAssertEqual(zoomLabel(menu), "Fit")
        app.buttons["zoom.in"].click()
        XCTAssertTrue(waitFor { self.zoomLabel(menu).hasSuffix("%") },
                      "zoom label after zoom-in: \(zoomLabel(menu))")
        app.buttons["zoom.out"].click()
        XCTAssertTrue(waitFor { self.zoomLabel(menu).hasSuffix("%") })
        menu.click()
        let fit = app.menuItems["Fit"]
        XCTAssertTrue(fit.waitForExistence(timeout: 5))
        fit.click()
        XCTAssertTrue(waitFor { self.zoomLabel(menu) == "Fit" })
    }

    private func zoomLabel(_ menu: XCUIElement) -> String {
        (menu.value as? String) ?? menu.label
    }

    /// The progress stage text via a snapshot: nil when the overlay is gone.
    /// Pure data, so it can't race the overlay's teardown like element
    /// property reads do.
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

    /// Polls a condition on the main run loop (XCUIElement state doesn't
    /// compose with XCTNSPredicateExpectation for arbitrary closures).
    private func waitFor(timeout: TimeInterval = 10,
                         _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return condition()
    }
}
