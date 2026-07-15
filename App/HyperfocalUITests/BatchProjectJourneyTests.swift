import XCTest

/// One session (plus a reopen) over multi-stack workflows: the shipped
/// Save-gating regression, the batch fuse queue, Export All, and a full
/// project save → reopen round trip with both results intact.
final class BatchProjectJourneyTests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    func testBatchFuseExportAllAndProjectRoundTrip() throws {
        let app = try launchApp(stacks: ["stack-a", "stack-b"])
        XCTAssertTrue(app.buttons["fusion.fuse-stack"].waitForExistence(timeout: 15))

        XCTContext.runActivity(named: "fuse stack-a alone") { _ in
            app.buttons["fusion.fuse-stack"].click()
            waitForFuseDone(app)
        }

        XCTContext.runActivity(named: "unfused selection keeps Save enabled (regression)") { _ in
            let rowB = app.buttons["stack.row.stack-b"]
            rowB.click()
            XCTAssertTrue(waitFor { rowB.isSelected })
            XCTAssertTrue(menuItemEnabled(app, menu: "File", item: "Save Project…"),
                          "Save must stay enabled with an unfused stack selected")
        }

        XCTContext.runActivity(named: "batch fuse the rest") { _ in
            let batch = app.buttons["fusion.fuse-enabled"]
            XCTAssertTrue(batch.waitForExistence(timeout: 5),
                          "Fuse N Stacks should exist with 2 enabled stacks")
            XCTAssertTrue(batch.isEnabled, "one stack is pending — queue must be ready")
            batch.click()
            // The queue starts asynchronously: wait for the run to visibly
            // begin (else "drained" can pass before it starts), then for it
            // to end with nothing pending.
            _ = waitFor(timeout: 15) { app.progressIndicators["progress.bar"].exists }
            XCTAssertTrue(waitFor(timeout: 120) {
                !app.progressIndicators["progress.bar"].exists && !batch.isEnabled
            }, "batch queue never drained")
        }

        try XCTContext.runActivity(named: "export all fused") { _ in
            let dir = Fixtures.out.appendingPathComponent("export-all", isDirectory: true)
            let result = try sendCommand(["action": "export-all", "dir": dir.path])
            XCTAssertTrue((result["detail"] ?? "").hasPrefix("2 stacks exported"),
                          "summary: \(result["detail"] ?? "")")
            let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            XCTAssertEqual(files.count, 2, "expected one file per stack: \(files)")
            for file in files {
                let info = try inspectImage(at: dir.appendingPathComponent(file))
                XCTAssertGreaterThan(info.width, 400)
            }
        }

        let project = Fixtures.out.appendingPathComponent("batch.hyperfocal")
        try XCTContext.runActivity(named: "save project via command") { _ in
            try sendCommand(["action": "save-project", "path": project.path])
            XCTAssertTrue(FileManager.default.fileExists(atPath: project.path))
        }
        app.terminate()

        try XCTContext.runActivity(named: "reopen: both stacks restored fused") { _ in
            let second = try launchApp(env: ["HYPERFOCAL_OPEN_PROJECT": project.path])
            let rowA = second.buttons["stack.row.stack-a"]
            let rowB = second.buttons["stack.row.stack-b"]
            XCTAssertTrue(rowA.waitForExistence(timeout: 30), "project did not open")
            XCTAssertTrue(rowB.exists)
            // Selected stack restored with its result: frames decode
            // ("(aligned)" input title = bookmark machinery worked cold)
            // and Export is live.
            XCTAssertTrue(waitFor(timeout: 30) {
                let title = second.staticTexts["input.pane.title"]
                return title.exists && text(of: title).contains("(aligned)")
            }, "restored project should decode frames")
            XCTAssertTrue(second.buttons["export.result"].isEnabled)
            // The other stack holds its result too.
            rowB.click()
            XCTAssertTrue(waitFor { rowB.isSelected })
            XCTAssertTrue(waitFor { second.buttons["export.result"].isEnabled },
                          "stack-b lost its result across the round trip")
        }
    }
}
