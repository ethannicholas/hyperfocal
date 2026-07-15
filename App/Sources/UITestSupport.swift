import Foundation
import Combine
import os

/// UI-test mode: launch-environment hooks consumed once at startup, so the
/// XCUITest suite can seed state without driving open/save panels (the
/// sandbox makes panel automation pointless — fixtures live in the app's
/// own container, which needs no grant). Inert unless HYPERFOCAL_UITEST=1;
/// never compiled into the probe (app target only).
///
/// Variables:
///  - HYPERFOCAL_UITEST=1        master switch (also selects the throwaway
///                               UserDefaults suite, see AppModel.settings)
///  - HYPERFOCAL_AUTOCONFIRM=1   answer every confirmation/prompt "yes" and
///                               swallow summary/failure alerts
///  - HYPERFOCAL_LOAD_STACK      colon-separated folder paths → ingest at
///                               launch (replaces, like Open Folder)
///  - HYPERFOCAL_OPEN_PROJECT    .hyperfocal path → open at launch
///  - HYPERFOCAL_SAVE_PROJECT    path → write the project there as soon as
///                               the first fuse settles (fixture generator
///                               for the open-project round-trip test)
@MainActor
enum UITestSupport {

    static var isActive: Bool {
        ProcessInfo.processInfo.environment["HYPERFOCAL_UITEST"] == "1"
    }

    private static var saveObserver: AnyCancellable?

    private static let log = Logger(subsystem: "org.hyperfocal", category: "uitest")

    static func activate(_ model: AppModel) {
        guard isActive else { return }
        let env = ProcessInfo.processInfo.environment
        log.notice("uitest mode active; LOAD_STACK=\(env["HYPERFOCAL_LOAD_STACK"] ?? "nil", privacy: .public) OPEN_PROJECT=\(env["HYPERFOCAL_OPEN_PROJECT"] ?? "nil", privacy: .public)")

        // Fresh throwaway defaults every run: a test that collapses a
        // section must not leak that into the next test's launch.
        AppModel.settings.removePersistentDomain(forName: "org.hyperfocal.uitest-settings")

        if env["HYPERFOCAL_AUTOCONFIRM"] == "1" {
            model.confirmAlertOverride = { _ in true }
            model.badFramePrompt = { _ in true }
            model.splitChoicePrompt = { _, _ in false }
            model.queueSummaryPresenter = { _ in }
            model.fuseFailureAlertOverride = { message in
                // A fuse failing under test is a test failure — make it
                // findable in the transcript rather than a silent stall.
                print("uitest: FUSE FAILED: \(message)")
            }
        }

        if let paths = env["HYPERFOCAL_LOAD_STACK"] {
            let urls = paths.split(separator: ":").map {
                URL(fileURLWithPath: String($0), isDirectory: true)
            }
            for url in urls {
                let listing = (try? FileManager.default
                    .contentsOfDirectory(atPath: url.path))?.count
                log.notice("ingest \(url.path, privacy: .public): \(listing.map(String.init) ?? "UNREADABLE", privacy: .public) entries")
            }
            model.ingest(urls: urls)
        } else if let path = env["HYPERFOCAL_OPEN_PROJECT"] {
            model.openProject(from: URL(fileURLWithPath: path))
        }

        if let path = env["HYPERFOCAL_SAVE_PROJECT"] {
            let url = URL(fileURLWithPath: path)
            // Write once, after the first fuse settles into a result.
            saveObserver = model.$phase.sink { [weak model] phase in
                guard phase == .done, let model else { return }
                saveObserver = nil
                model.writeProject(to: url)
            }
        }
    }
}
