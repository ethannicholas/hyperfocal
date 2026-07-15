import XCTest

/// One session over the stack list: loading, counts, include toggles,
/// row selection, disclosure, unfused-save gating, zoom, and the close
/// flows — everything that doesn't need a fuse.
final class StackListJourneyTests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    func testStackListJourney() throws {
        let framesA = try Fixtures.frames(in: "stack-a")
        let app = try launchApp(stacks: ["stack-a", "stack-b"])

        let count = app.staticTexts["stack.count"]
        XCTContext.runActivity(named: "load: rows, count, fuse enablement") { _ in
            XCTAssertTrue(count.waitForExistence(timeout: 15))
            // The count mirrors the SELECTED stack (stack-a loads selected).
            XCTAssertEqual(text(of: count), "\(framesA.count) of \(framesA.count)")
            XCTAssertTrue(app.buttons["stack.row.stack-a"].exists)
            XCTAssertTrue(app.buttons["stack.row.stack-b"].exists)
            XCTAssertTrue(app.buttons["fusion.fuse-stack"].isEnabled)
            XCTAssertEqual(text(of: app.staticTexts["output.pane.hint"]), "Press “Fuse Stack”")
        }

        XCTContext.runActivity(named: "unfused project: Save enabled (regression)") { _ in
            XCTAssertTrue(menuItemEnabled(app, menu: "File", item: "Save Project"))
            XCTAssertTrue(menuItemEnabled(app, menu: "File", item: "Save Project As…"))
        }

        XCTContext.runActivity(named: "disclosure collapse hides frame rows") { _ in
            let firstFrame = app.staticTexts["frame.row.\(framesA[0])"]
            XCTAssertTrue(firstFrame.exists)
            app.buttons["stack.row.stack-a.disclose"].click()
            XCTAssertTrue(waitFor { !firstFrame.exists }, "frames still listed")
            app.buttons["stack.row.stack-a.disclose"].click()
            XCTAssertTrue(firstFrame.waitForExistence(timeout: 5))
        }

        XCTContext.runActivity(named: "row selection") { _ in
            let rowB = app.buttons["stack.row.stack-b"]
            rowB.click()
            XCTAssertTrue(waitFor { rowB.isSelected }, "stack-b never selected")
            app.buttons["stack.row.stack-a"].click()
            XCTAssertTrue(waitFor { app.buttons["stack.row.stack-a"].isSelected })
        }

        XCTContext.runActivity(named: "All/None drive count and Fuse") { _ in
            app.buttons["stack.include-none"].click()
            XCTAssertTrue(waitFor { text(of: count).hasPrefix("0 of") },
                          "count after None: \(text(of: count))")
            XCTAssertFalse(app.buttons["fusion.fuse-stack"].isEnabled)
            app.buttons["stack.include-all"].click()
            XCTAssertTrue(waitFor { !text(of: count).hasPrefix("0 of") })
            XCTAssertTrue(app.buttons["fusion.fuse-stack"].isEnabled)
        }

        XCTContext.runActivity(named: "single frame checkbox") { _ in
            let before = text(of: count)
            let box = app.checkBoxes["frame.row.\(framesA[0]).included"]
            box.click()
            XCTAssertTrue(waitFor { text(of: count) != before }, "count never moved")
            box.click()
            XCTAssertTrue(waitFor { text(of: count) == before })
        }

        XCTContext.runActivity(named: "mouse-driven slider (the one context "
                               + "where XCUITest slider mechanics work)") { _ in
            setSlider(app, app.sliders["fusion.slider.sharpness"],
                      valueText: app.staticTexts["fusion.slider.sharpness.value"],
                      to: 0.9)
            XCTAssertTrue(app.buttons["fusion.reset"].waitForExistence(timeout: 5),
                          "Reset should appear once settings leave defaults")
            app.buttons["fusion.reset"].click()
        }

        XCTContext.runActivity(named: "section collapse/expand") { _ in
            let header = app.buttons["section.fusion"]
            let fuse = app.buttons["fusion.fuse-stack"]
            XCTAssertEqual(header.value as? String, "expanded")
            header.click()
            XCTAssertTrue(waitFor { !fuse.exists })
            XCTAssertEqual(header.value as? String, "collapsed")
            header.click()
            XCTAssertTrue(fuse.waitForExistence(timeout: 5))
        }

        XCTContext.runActivity(named: "zoom controls") { _ in
            let menu = app.menuButtons["zoom.menu"]
            XCTAssertEqual(text(of: menu), "Fit")
            // Zooming no-ops until the input preview has decoded (zoom is
            // relative to the displayed image's size).
            XCTAssertTrue(waitFor(timeout: 15) {
                !app.staticTexts["input.pane.hint"].exists
            }, "input preview never decoded")
            app.buttons["zoom.in"].click()
            XCTAssertTrue(waitFor { text(of: menu).hasSuffix("%") },
                          "zoom label: \(text(of: menu))")
            app.buttons["zoom.out"].click()
            menu.click()
            let fit = app.menuItems["Fit"]
            XCTAssertTrue(fit.waitForExistence(timeout: 5))
            fit.click()
            XCTAssertTrue(waitFor { text(of: menu) == "Fit" })
        }

        XCTContext.runActivity(named: "close stack flattens; close project empties") { _ in
            clickMenuItem(app, menu: "File", item: "Close Stack")
            XCTAssertTrue(waitFor {
                !app.buttons["stack.row.stack-a"].exists
                    && !app.buttons["stack.row.stack-b"].exists
            }, "tree should flatten with one stack left")
            XCTAssertTrue(app.staticTexts["stack.count"].exists)
            clickMenuItem(app, menu: "File", item: "Close Project")
            XCTAssertTrue(app.buttons["stack.open-folder"].waitForExistence(timeout: 10))
            XCTAssertFalse(menuItemEnabled(app, menu: "File", item: "Close Project"))
        }
    }
}
