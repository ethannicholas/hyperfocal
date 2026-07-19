#include <QApplication>
#include <QDir>
#include <QIcon>
#include <QImage>
#include <QQmlApplicationEngine>
#include <QQuickWindow>
#include <QTimer>
#include <QUrl>

#include "LutImageProvider.h"
#include "PaneItem.h"
#include "Shell.h"
#include "hyperfocal_bridge.h"

// --selftest <stack-dir> <out.tif> [screenshot.png]
//
// The walking-skeleton proof, self-driven: open → fuse → wait → set tone →
// export → grab the window. Exits 0 only if the export lands. This is the
// seed of the Qt-side journey harness (plan Phase 2: both frontends run
// the same functional journeys) — no AX/screen driving involved.
namespace {

struct SelfTest {
    QString stackDir;
    QString stack2Dir;    // HFQT_STACK2: batch journey (two stacks)
    bool stack2Opened = false;
    QString outPath;
    QString shotPath;
    bool sawRunning = false;
    bool fused = false;
    bool done = false;
    // Verdicts collected by the done block; the finish poll (which waits
    // out the async input-frame decode, then runs the zoom-cycle
    // journey) turns them into the exit code.
    bool exported = false, depthExported = false;
    bool wasStale = false, staleAfterEdit = false;
    bool exclusionOK = false, batchOK = false, cropOK = false;
    bool toneKeptPixels = false, depthBumpedPixels = false, fullRes = false;
    bool inputOK = false, zoomOK = true;
    bool undoOK = false, projectOK = false, previewOK = false;
    bool cycledSource = false;
    bool retouchOK = false;
    QString projectFile;
    QString expectedInput;    // selected frame's name
    int finishStage = 0;      // 0 input-wait, 1..3 zoom cycle, 4 finish
    int finishTries = 0;
    int stageTicks = 0;
    int changedCount = 0;      // Shell::changed emissions (see stage 6)
    int changedAtRetouch = 0;
    QImage zoomPrev, zoomShotA, strokePre;
};

void runSelfTest(QQmlApplicationEngine *engine, SelfTest *state) {
    auto *shell = engine->singletonInstance<Shell *>("Hyperfocal", "Shell");
    if (!shell) { QCoreApplication::exit(3); return; }

    if (!shell->openStack(QUrl::fromLocalFile(state->stackDir))) {
        QCoreApplication::exit(4);
        return;
    }

    // Witness the fine-grained notification path: QML only re-reads on
    // these signals, so a journey that polls the bridge directly would
    // pass even if the UI were stuck (the RetouchSession-observer bug).
    QObject::connect(shell, &Shell::changed, engine,
                     [state] { ++state->changedCount; });

    auto *poll = new QTimer(engine);
    QObject::connect(poll, &QTimer::timeout, engine, [engine, shell, state] {
        if (state->done) return;
        // HFQT_STACK2: a second stack turns the run into the batch journey
        // ("Fuse N Stacks" must walk both and leave both fused). Opened
        // once the first load settles — loads refuse ingests while
        // running, exactly like drops on the native app.
        if (!state->stack2Dir.isEmpty() && !state->stack2Opened) {
            if (shell->isRunning()) return;
            if (shell->openStack(QUrl::fromLocalFile(state->stack2Dir)))
                state->stack2Opened = true;
            return;
        }
        if (!state->fused) {
            if (shell->canFuse()) {
                state->fused = true;
                if (state->stack2Dir.isEmpty()) shell->fuse();
                else shell->fuseEnabledStacks();
            }
            return;
        }
        if (shell->isRunning()) {
            state->sawRunning = true;
            return;
        }
        // Done when we either watched it run or the display appeared — a
        // small stack can fuse entirely between two polls.
        if (!state->sawRunning && !shell->hasDisplay()) return;
        state->done = true;
        // Zero-copy currency: tone edits render through the LUT shader and
        // must NOT invalidate display pixels — the epoch may not move.
        const int epochBeforeTone = shell->displayEpoch();
        // Bracketed like a slider drag, so the change records ONE
        // undoable edit (the undo journey below unwinds it).
        shell->toneEditing(true);
        shell->setExposure(0.5);  // tone reaches the preview + export
        shell->toneEditing(false);
        state->toneKeptPixels = shell->displayEpoch() == epochBeforeTone;
        // Full-res currency: the display is the result itself, not a capped
        // preview (HFQT_EXPECT_DISPLAY=WxH from a runner that knows the
        // stack's frame size).
        state->fullRes = true;
        const QByteArray expectSize = qgetenv("HFQT_EXPECT_DISPLAY");
        if (!expectSize.isEmpty()) {
            const auto parts = expectSize.split('x');
            state->fullRes = parts.size() == 2
                && shell->displayWidth() == parts[0].toInt()
                && shell->displayHeight() == parts[1].toInt();
        }
        // TIFF via the extension map, plus DNG through the same seam —
        // the two per-call formats the format map must route correctly.
        state->exported =
            shell->exportTo(QUrl::fromLocalFile(state->outPath))
            && shell->exportTo(QUrl::fromLocalFile(state->outPath + ".dng"));
        // Depth mode displays + exports the (untoned) depth map — and the
        // pixel swap must move the epoch, or the pane would keep showing
        // the result's tiles.
        shell->setDepthMode(true);
        state->depthBumpedPixels = shell->displayEpoch() != epochBeforeTone;
        state->depthExported =
            shell->exportTo(QUrl::fromLocalFile(state->outPath + ".depth.tif"));
        shell->setDepthMode(false);
        // Crop: set-crop (the UITest seam's semantics) must present
        // through displayCrop WITHOUT touching pixels — crop is a
        // viewport, the epoch may not move — and export the rect's size
        // (the runner checks the file's dimensions; the 5° angle
        // exercises the rotated sampler). Stays set through the window
        // grab so shots show the cropped panes; the finish poll clears
        // it and checks the clear.
        const int epochBeforeCrop = shell->displayEpoch();
        shell->setCrop(101, 51, 400, 300, 5);
        state->cropOK =
            shell->displayCrop() == QRectF(101, 51, 400, 300)
            && shell->displayCropAngle() == 5
            && shell->displayEpoch() == epochBeforeCrop
            && shell->exportTo(QUrl::fromLocalFile(state->outPath + ".crop.tif"));
        // Batch journey: both stacks listed, both fused, nothing pending —
        // checked BEFORE the staleness edit below re-pends a stack.
        state->batchOK = true;
        if (!state->stack2Dir.isEmpty()) {
            const QVariantList stacks = shell->stacks();
            state->batchOK = stacks.size() == 2
                && shell->pendingStackCount() == 0;
            for (const QVariant &row : stacks)
                state->batchOK = state->batchOK
                    && row.toMap().value(QStringLiteral("status")).toInt() == 2;
            if (!state->batchOK) {
                qWarning() << "selftest batch state: pending"
                           << shell->pendingStackCount() << "stacks" << stacks;
            }
        }
        // Moving a fusion slider must mark the result stale (canFuse back
        // on) — the staleness contract the sidebar depends on.
        state->wasStale = shell->canFuse();
        shell->setSlider(QStringLiteral("fusion.slider.sharpness"),
                         shell->slider(QStringLiteral("fusion.slider.sharpness")) + 2);
        state->staleAfterEdit = shell->canFuse();
        // HFQT_EXPECT_EXCLUDED=<index>: that frame must have lost its
        // checkbox during the fuse — proves the bad-frame confirm went
        // through the bridge dialog seam (with HFQT_AUTOCONFIRM answering).
        state->exclusionOK = true;
        const QByteArray expect = qgetenv("HFQT_EXPECT_EXCLUDED");
        if (!expect.isEmpty()) {
            const int idx = expect.toInt();
            const QVariantList frames = shell->frames();
            // The excluded frame must also carry its issue summary — the
            // sidebar badge's data path.
            state->exclusionOK = idx < frames.size()
                && !frames[idx].toMap().value(QStringLiteral("included")).toBool()
                && !frames[idx].toMap().value(QStringLiteral("issue"))
                        .toString().isEmpty();
        }
        // Select a frame: the input pane must follow (async decode — the
        // finish poll below waits for it, then grabs and exits).
        const QVariantList frames = shell->frames();
        if (frames.size() > 1) {
            state->expectedInput =
                frames[1].toMap().value(QStringLiteral("name")).toString();
            shell->selectFrame(1);
        }
        PaneItem *pane = nullptr;
        {
            const auto roots = engine->rootObjects();
            if (!roots.isEmpty()) {
                pane = roots.first()->findChild<PaneItem *>(
                    QStringLiteral("outputPaneItem"));
            }
        }
        auto *finish = new QTimer(engine);
        QObject::connect(finish, &QTimer::timeout, engine, [engine, shell,
                                                            state, finish,
                                                            pane] {
            auto grab = [engine]() -> QImage {
                const auto roots = engine->rootObjects();
                if (roots.isEmpty()) return QImage();
                if (auto *window = qobject_cast<QQuickWindow *>(roots.first()))
                    return window->grabWindow();
                return QImage();
            };
            // Settled = two consecutive identical grabs (tile fetches
            // arrive over frames; grabWindow forces a render per tick).
            auto stable = [state, &grab]() -> bool {
                QImage now = grab();
                const bool same = !now.isNull() && now == state->zoomPrev;
                state->zoomPrev = now;
                return same;
            };
            auto advance = [state](int stage) {
                state->finishStage = stage;
                state->stageTicks = 0;
                state->zoomPrev = QImage();
            };
            switch (state->finishStage) {
            case 0:    // async input-frame decode, ~10s ceiling
                // inputLoading must have cleared: the title names the new
                // frame as soon as it's selected, but the pane serves the
                // PREVIOUS image until the decode lands — grabbing the
                // zoom reference before then compares against stale pixels.
                state->inputOK = state->expectedInput.isEmpty()
                    || (shell->hasInput() && !shell->inputLoading()
                        && shell->inputTitle().startsWith(state->expectedInput));
                if (!state->inputOK && ++state->finishTries < 40) return;
                // Zoom-cycle journey: deep zoom, out, and back — the same
                // pixels must return (a stale coarse tile left covering
                // the fine level would blur the pane; the layering trap).
                if (!pane) { advance(4); return; }
                pane->setZoom(8);
                advance(1);
                return;
            case 1:    // settle at 8x, keep the reference grab
                if (stable()) {
                    state->zoomShotA = state->zoomPrev;
                    pane->setZoom(0.2);
                    advance(2);
                } else if (++state->stageTicks > 40) {
                    qWarning() << "selftest zoom: stage 1 (8x) never settled";
                    state->zoomOK = false;
                    advance(4);
                }
                return;
            case 2:    // settle zoomed out
                if (stable()) {
                    pane->setZoom(8);
                    advance(3);
                } else if (++state->stageTicks > 40) {
                    qWarning() << "selftest zoom: stage 2 (0.2x) never settled";
                    state->zoomOK = false;
                    advance(4);
                }
                return;
            case 3:    // back at 8x: detail must have returned
                if (stable()) {
                    state->zoomOK = state->zoomPrev == state->zoomShotA;
                    if (!state->zoomOK) {
                        qWarning() << "selftest zoom: pixels differ after "
                                      "zoom cycle";
                        if (!state->shotPath.isEmpty()) {
                            state->zoomShotA.save(state->shotPath
                                                  + ".zoomA.png");
                            state->zoomPrev.save(state->shotPath
                                                 + ".zoomB.png");
                        }
                    }
                    pane->setZoom(1);
                    advance(4);
                } else if (++state->stageTicks > 40) {
                    qWarning() << "selftest zoom: stage 3 (back to 8x) never "
                                  "settled";
                    state->zoomOK = false;
                    advance(4);
                }
                return;
            case 4:    // wrap-up: grab, crop clear, undo, save + reopen
                if (!state->shotPath.isEmpty()) {
                    const QImage shot = grab();
                    if (!shot.isNull()) shot.save(state->shotPath);
                }
                shell->setCrop(0, 0, 0, 0, 0);
                state->cropOK = state->cropOK
                    && shell->displayCrop().isEmpty();
                // Crop-mode session: begin initializes to the full
                // canvas and hides displayCrop; accepting the untouched
                // full-canvas rect folds back to "no crop".
                state->cropOK = state->cropOK
                    && shell->beginCrop() && shell->cropMode()
                    && shell->editCrop()
                        == QRectF(0, 0, shell->displayWidth(),
                                  shell->displayHeight())
                    && shell->displayCrop().isEmpty()
                    && shell->acceptCrop() && !shell->cropMode()
                    && shell->displayCrop().isEmpty();
                // Sidebar collapse round-trip: model-owned state (the
                // shared settings suite may carry any starting value, so
                // assert the flip and the restore, not absolutes) — and
                // it must ride the changed() fingerprint for QML.
                {
                    const bool was =
                        shell->collapsedSections().contains(QStringLiteral("tone"));
                    shell->toggleSection(QStringLiteral("tone"));
                    state->cropOK = state->cropOK
                        && shell->collapsedSections().contains(QStringLiteral("tone"))
                            != was;
                    shell->toggleSection(QStringLiteral("tone"));
                    state->cropOK = state->cropOK
                        && shell->collapsedSections().contains(QStringLiteral("tone"))
                            == was;
                }
                // Undo journey: the tone edit above guarantees history;
                // undo all the way and the model must land back neutral
                // (exposure 0), then one redo must take.
                state->undoOK = shell->canUndo();
                for (int guard = 64; shell->canUndo() && guard > 0; --guard)
                    state->undoOK = shell->undo() && state->undoOK;
                state->undoOK = state->undoOK && !shell->canUndo()
                    && shell->slider(QStringLiteral("tone.slider.exposure")) == 0.0
                    && shell->canRedo() && shell->redo();
                // Noise-floor preview: while the bracket holds, the
                // display must become a data visualization (the live
                // depth preview builds async — stage 5 waits it out).
                shell->noiseFloorEditing(true);
                shell->setSlider(QStringLiteral("fusion.slider.noise-floor"),
                                 shell->slider(QStringLiteral(
                                     "fusion.slider.noise-floor")) + 0.05);
                advance(5);
                return;
            case 5: {   // noise-floor preview lands (async build)
                const bool isData = shell->displayIsData();
                if (!isData && ++state->stageTicks < 40) return;
                shell->noiseFloorEditing(false);
                // End restores the normal (non-data) display synchronously.
                state->previewOK = isData && !shell->displayIsData();
                // Retouch journey: enter (async source decode — stage 6
                // waits for canPaint).
                state->changedAtRetouch = state->changedCount;
                state->retouchOK = shell->enterRetouch()
                    && shell->retouchMode();
                advance(6);
                return;
            }
            case 6: {   // retouch source decodes, then a stroke round-trip
                if (!shell->retouchCanPaint() && ++state->stageTicks < 40) {
                    // hover keeps the auto-pick target current while the
                    // decode lands
                    shell->retouchHover(shell->displayWidth() / 2.0,
                                        shell->displayHeight() / 2.0);
                    return;
                }
                // Paint from a NEIGHBOR frame, not the default pick:
                // at the image center the fused result can be exactly the
                // default frame's pixels (winner-take-all), which would
                // make the stage-7 visibility check vacuously fail.
                if (shell->retouchCanPaint() && !state->cycledSource) {
                    state->cycledSource = true;
                    state->stageTicks = 0;
                    shell->retouchCycleSource(1);
                    return;     // the new frame decodes async — re-wait
                }
                const bool paintable = shell->retouchCanPaint();
                // The session's async load must have driven the shell's
                // changed() signal — the QML UI depends on it (a silent
                // load leaves "Loading source…" stuck forever).
                state->retouchOK = state->retouchOK
                    && state->changedCount > state->changedAtRetouch;
                // A short diagonal stroke through the center must mark
                // edits, bump the display epoch through the dirty-rect
                // channel, and scope undo to strokes; undo takes the
                // stroke back (edits stay marked), Revert All clears,
                // and Done exits the mode.
                const double rcx = shell->displayWidth() / 2.0;
                const double rcy = shell->displayHeight() / 2.0;
                state->strokePre = grab();
                const int epochBefore = shell->displayEpoch();
                shell->retouchStrokeBegin(rcx - 40, rcy - 40);
                shell->retouchStrokeMove(rcx - 40, rcy - 40,
                                         rcx + 40, rcy + 40);
                shell->retouchStrokeEnd();
                state->retouchOK = state->retouchOK && paintable
                    && shell->retouchHasEdits()
                    && shell->displayEpoch() != epochBefore
                    && shell->undoTitle() == QStringLiteral("Undo Stroke");
                advance(7);
                return;
            }
            case 7: {   // the stroke must be VISIBLE (stale-texture trap)
                // Settled pixels must differ from the pre-stroke grab —
                // tile eviction without texture replacement once left
                // strokes invisible until a zoom/pan.
                const QImage now = grab();
                if (now == state->strokePre && ++state->stageTicks < 12)
                    return;
                state->retouchOK = state->retouchOK
                    && !now.isNull() && now != state->strokePre
                    && shell->undo()
                    && shell->retouchHasEdits()
                    && shell->revertRetouch()
                    && !shell->retouchHasEdits()
                    && shell->exitRetouch()
                    && !shell->retouchMode();
                // Project round-trip: save must clear the dirty flag and
                // set the path; reopening the file must restore a fused
                // stack (stage 8 waits out the load). Compare paths with
                // forward slashes: the bridge echoes them that way, while a
                // Windows runner passes the out path with backslashes.
                state->projectFile = state->outPath + ".hyperfocal";
                state->projectOK =
                    shell->saveProject(QUrl::fromLocalFile(state->projectFile))
                    && !shell->hasUnsavedWork()
                    && QDir::fromNativeSeparators(shell->projectPath())
                        == QDir::fromNativeSeparators(state->projectFile);
                if (state->projectOK)
                    shell->openStack(QUrl::fromLocalFile(state->projectFile));
                advance(8);
                return;
            }
            case 8: {   // reload settles: a stack is back, still fused
                if (shell->isRunning()) { state->stageTicks = 0; return; }
                const QVariantList stacks = shell->stacks();
                const bool reloaded = stacks.size() >= 1
                    && stacks[0].toMap().value(QStringLiteral("status"))
                           .toInt() == 2;
                if (!reloaded && ++state->stageTicks < 40) return;
                state->projectOK = state->projectOK && reloaded;
                // New Project must REPLACE the stacks (hf_load_stack
                // keeps drop/add semantics) — in the batch variant this
                // collapses the reloaded two stacks back to one.
                state->projectOK = state->projectOK
                    && shell->confirmNewProject()
                    && shell->newProject(QUrl::fromLocalFile(state->stackDir));
                advance(9);
                return;
            }
            case 9: {   // new-project load settles: exactly one stack
                if (shell->isRunning()) { state->stageTicks = 0; return; }
                const bool replaced = shell->stacks().size() == 1;
                if (!replaced && ++state->stageTicks < 40) return;
                state->projectOK = state->projectOK && replaced;
                break;
            }
            default:
                break;
            }
            finish->stop();
            if (!state->exported) { QCoreApplication::exit(5); return; }
            if (!state->depthExported) { QCoreApplication::exit(6); return; }
            if (state->wasStale || !state->staleAfterEdit) {
                QCoreApplication::exit(7);
                return;
            }
            if (!state->exclusionOK) { QCoreApplication::exit(8); return; }
            if (!state->toneKeptPixels || !state->depthBumpedPixels) {
                QCoreApplication::exit(9);
                return;
            }
            if (!state->fullRes) { QCoreApplication::exit(10); return; }
            if (!state->batchOK) { QCoreApplication::exit(11); return; }
            if (!state->inputOK) { QCoreApplication::exit(12); return; }
            if (!state->cropOK) { QCoreApplication::exit(13); return; }
            if (!state->zoomOK) { QCoreApplication::exit(14); return; }
            if (!state->undoOK) { QCoreApplication::exit(15); return; }
            if (!state->projectOK) { QCoreApplication::exit(16); return; }
            if (!state->previewOK) { QCoreApplication::exit(17); return; }
            if (!state->retouchOK) { QCoreApplication::exit(18); return; }
            QCoreApplication::exit(0);
        });
        // First tick after the queued change signal has delivered, so the
        // grab shows the settled UI.
        finish->start(250);
    });
    poll->start(200);

    // Backstop: a hung fuse must fail the test, not wedge it.
    QTimer::singleShot(300000, engine, [] { QCoreApplication::exit(2); });
}

}  // namespace

int main(int argc, char *argv[]) {
    // The Qt shell keeps its own settings store: AppModel reads the suite
    // name before hf_init touches any persisted value, so nothing bleeds
    // between this shell and the native app (whose org.hyperfocal.settings
    // this process would otherwise share). Overridable for debugging.
    if (qEnvironmentVariableIsEmpty("HYPERFOCAL_SETTINGS_SUITE"))
        qputenv("HYPERFOCAL_SETTINGS_SUITE", "org.hyperfocal.qtshell-settings");
    QApplication app(argc, argv);  // QtWidgets: modal QMessageBox dialogs
    app.setWindowIcon(QIcon(QStringLiteral(":/AppIcon.png")));
#ifndef Q_OS_MACOS
    // On macOS Qt's Cocoa loop pumps the CFRunLoop, which drains the Swift
    // side's DispatchQueue.main. Elsewhere nothing does — pump it from the
    // event loop (hyperfocal_bridge.h threading contract).
    auto *pump = new QTimer(&app);
    QObject::connect(pump, &QTimer::timeout, &app, [] { hf_pump_main(); });
    pump->start(5);
#endif
    QQmlApplicationEngine engine;
    engine.addImageProvider(QStringLiteral("hflut"), new LutImageProvider);
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed,
                     &app, [] { QCoreApplication::exit(1); },
                     Qt::QueuedConnection);
    engine.loadFromModule("Hyperfocal", "Main");

    const QStringList args = app.arguments();
    SelfTest state;
    if (args.size() >= 4 && args[1] == QStringLiteral("--selftest")) {
        state.stackDir = args[2];
        state.stack2Dir = QString::fromLocal8Bit(qgetenv("HFQT_STACK2"));
        state.outPath = args[3];
        state.shotPath = args.size() >= 5 ? args[4] : QString();
        // After the QML engine settles, so the Shell singleton exists.
        QTimer::singleShot(0, &engine, [&engine, &state] {
            runSelfTest(&engine, &state);
        });
    }
    return app.exec();
}
