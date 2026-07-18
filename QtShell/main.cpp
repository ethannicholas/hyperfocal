#include <QApplication>
#include <QQmlApplicationEngine>
#include <QQuickWindow>
#include <QTimer>
#include <QUrl>

#include "LutImageProvider.h"
#include "Shell.h"

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
    // out the async input-frame decode) turns them into the exit code.
    bool exported = false, depthExported = false;
    bool wasStale = false, staleAfterEdit = false;
    bool exclusionOK = false, batchOK = false, cropOK = false;
    bool toneKeptPixels = false, depthBumpedPixels = false, fullRes = false;
    QString expectedInput;    // selected frame's name
    int finishTries = 0;
};

void runSelfTest(QQmlApplicationEngine *engine, SelfTest *state) {
    auto *shell = engine->singletonInstance<Shell *>("Hyperfocal", "Shell");
    if (!shell) { QCoreApplication::exit(3); return; }

    if (!shell->openStack(QUrl::fromLocalFile(state->stackDir))) {
        QCoreApplication::exit(4);
        return;
    }

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
        shell->setExposure(0.5);  // tone reaches the preview + export
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
        state->exported =
            shell->exportTo(QUrl::fromLocalFile(state->outPath));
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
            state->exclusionOK = idx < frames.size()
                && !frames[idx].toMap().value(QStringLiteral("included")).toBool();
        }
        // Select a frame: the input pane must follow (async decode — the
        // finish poll below waits for it, then grabs and exits).
        const QVariantList frames = shell->frames();
        if (frames.size() > 1) {
            state->expectedInput =
                frames[1].toMap().value(QStringLiteral("name")).toString();
            shell->selectFrame(1);
        }
        auto *finish = new QTimer(engine);
        QObject::connect(finish, &QTimer::timeout, engine, [engine, shell,
                                                            state, finish] {
            const bool inputOK = state->expectedInput.isEmpty()
                || (shell->hasInput()
                    && shell->inputTitle().startsWith(state->expectedInput));
            // ~10s ceiling for a small preview decode, then fail loudly.
            if (!inputOK && ++state->finishTries < 40) return;
            finish->stop();
            if (!state->shotPath.isEmpty()) {
                const auto roots = engine->rootObjects();
                if (!roots.isEmpty()) {
                    if (auto *window = qobject_cast<QQuickWindow *>(roots.first())) {
                        window->grabWindow().save(state->shotPath);
                    }
                }
            }
            shell->setCrop(0, 0, 0, 0, 0);
            state->cropOK = state->cropOK && shell->displayCrop().isEmpty();
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
            if (!inputOK) { QCoreApplication::exit(12); return; }
            if (!state->cropOK) { QCoreApplication::exit(13); return; }
            QCoreApplication::exit(0);
        });
        // First tick after the queued change signal has delivered, so the
        // grab shows the settled UI.
        finish->start(250);
    });
    poll->start(200);

    // Backstop: a hung fuse must fail the test, not wedge it.
    QTimer::singleShot(180000, engine, [] { QCoreApplication::exit(2); });
}

}  // namespace

int main(int argc, char *argv[]) {
    QApplication app(argc, argv);  // QtWidgets: modal QMessageBox dialogs
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
