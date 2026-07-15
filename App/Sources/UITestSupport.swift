import AppKit
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
///
/// Beyond launch seeding, an active session accepts commands over
/// DistributedNotificationCenter (name "org.hyperfocal.uitest.command",
/// JSON in the notification object). The runner can't write into the
/// app's container, so requests arrive as notifications; the app can
/// write there, so each command's JSON names a `result` path inside the
/// container that gets `{"ok": ...}` when the command finishes — the
/// runner (which CAN read the container) polls it. Commands:
///
///   {"action": "export",     "path": p, "result": r}   current format/space/tone
///   {"action": "export-all", "dir": d,  "result": r}
///   {"action": "save-project", "path": p, "result": r}
///   {"action": "set-slider", "id": <accessibility id>, "value": v, "result": r}
///       — sets the slider's bound model value directly. XCUITest cannot
///       reliably move SwiftUI sliders in some window states (adjust and
///       synthesized drags no-op on elements that report hittable), so
///       journeys set values here and verify the UI's value label AND the
///       rendered output; direct mouse-drag coverage lives in the one
///       context where it provably works (StackListJourney, pre-fuse).
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

        // Fill the visible screen: offscreen controls are invisible to
        // XCUITest coordinate math (adjust/drag/click silently no-op), the
        // sidebar grows past small windows once the retouch section appears,
        // and a window taller than the screen puts the zoom bar off-screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let window = NSApp.windows.first(where: { $0.isVisible }),
               let screen = NSScreen.main {
                window.setFrame(screen.visibleFrame, display: true)
            }
        }

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

        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("org.hyperfocal.uitest.command"),
            object: nil, queue: .main) { [weak model] note in
            guard let json = note.object as? String,
                  let data = json.data(using: .utf8),
                  let command = (try? JSONSerialization.jsonObject(with: data))
                      as? [String: String] else {
                log.error("uitest command unparseable: \(String(describing: note.object), privacy: .public)")
                return
            }
            MainActor.assumeIsolated {
                guard let model else { return }
                handle(command, model: model)
            }
        }
    }

    private static func handle(_ command: [String: String], model: AppModel) {
        log.notice("uitest command: \(command.description, privacy: .public)")
        func finish(_ ok: Bool, _ detail: String = "") {
            guard let resultPath = command["result"] else { return }
            let payload = (try? JSONSerialization.data(withJSONObject:
                ["ok": ok ? "1" : "0", "detail": detail])) ?? Data()
            try? payload.write(to: URL(fileURLWithPath: resultPath))
        }
        switch command["action"] {
        case "export":
            guard let path = command["path"] else { return finish(false, "no path") }
            finish(model.writeExport(to: URL(fileURLWithPath: path)))
        case "export-all":
            guard let dir = command["dir"] else { return finish(false, "no dir") }
            let url = URL(fileURLWithPath: dir, isDirectory: true)
            try? FileManager.default.createDirectory(at: url,
                                                     withIntermediateDirectories: true)
            Task { @MainActor in
                finish(true, await model.exportAllFused(to: url))
            }
        case "save-project":
            guard let path = command["path"] else { return finish(false, "no path") }
            finish(model.writeProject(to: URL(fileURLWithPath: path)))
        case "set-slider":
            guard let id = command["id"], let raw = command["value"],
                  let value = Double(raw) else { return finish(false, "bad args") }
            switch id {
            case "fusion.slider.sharpness": model.sharpnessSigma = value
            case "fusion.slider.noise-floor": model.noiseFloor = value
            case "fusion.slider.median-radius": model.medianRadius = value
            case "fusion.slider.blend-radius": model.blendRadius = value
            case "tone.slider.exposure": model.tone.exposure = value
            case "tone.slider.contrast": model.tone.contrast = value
            case "tone.slider.highlights": model.tone.highlights = value
            case "tone.slider.shadows": model.tone.shadows = value
            case "tone.slider.whites": model.tone.whites = value
            case "tone.slider.blacks": model.tone.blacks = value
            default: return finish(false, "unknown slider \(id)")
            }
            finish(true)
        default:
            finish(false, "unknown action \(command["action"] ?? "nil")")
        }
    }
}
