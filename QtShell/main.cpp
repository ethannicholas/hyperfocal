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
        const bool toneKeptPixels = shell->displayEpoch() == epochBeforeTone;
        // Full-res currency: the display is the result itself, not a capped
        // preview (HFQT_EXPECT_DISPLAY=WxH from a runner that knows the
        // stack's frame size).
        bool fullRes = true;
        const QByteArray expectSize = qgetenv("HFQT_EXPECT_DISPLAY");
        if (!expectSize.isEmpty()) {
            const auto parts = expectSize.split('x');
            fullRes = parts.size() == 2
                && shell->displayWidth() == parts[0].toInt()
                && shell->displayHeight() == parts[1].toInt();
        }
        const bool exported =
            shell->exportTo(QUrl::fromLocalFile(state->outPath));
        // Depth mode displays + exports the (untoned) depth map — and the
        // pixel swap must move the epoch, or the pane would keep showing
        // the result's tiles.
        shell->setDepthMode(true);
        const bool depthBumpedPixels = shell->displayEpoch() != epochBeforeTone;
        const bool depthExported =
            shell->exportTo(QUrl::fromLocalFile(state->outPath + ".depth.tif"));
        shell->setDepthMode(false);
        // Batch journey: both stacks listed, both fused, nothing pending —
        // checked BEFORE the staleness edit below re-pends a stack.
        bool batchOK = true;
        if (!state->stack2Dir.isEmpty()) {
            const QVariantList stacks = shell->stacks();
            batchOK = stacks.size() == 2 && shell->pendingStackCount() == 0;
            for (const QVariant &row : stacks)
                batchOK = batchOK
                    && row.toMap().value(QStringLiteral("status")).toInt() == 2;
            if (!batchOK) {
                qWarning() << "selftest batch state: pending"
                           << shell->pendingStackCount() << "stacks" << stacks;
            }
        }
        // Moving a fusion slider must mark the result stale (canFuse back
        // on) — the staleness contract the sidebar depends on.
        const bool wasStale = shell->canFuse();
        shell->setSlider(QStringLiteral("fusion.slider.sharpness"),
                         shell->slider(QStringLiteral("fusion.slider.sharpness")) + 2);
        const bool staleAfterEdit = shell->canFuse();
        // HFQT_EXPECT_EXCLUDED=<index>: that frame must have lost its
        // checkbox during the fuse — proves the bad-frame confirm went
        // through the bridge dialog seam (with HFQT_AUTOCONFIRM answering).
        bool exclusionOK = true;
        const QByteArray expect = qgetenv("HFQT_EXPECT_EXCLUDED");
        if (!expect.isEmpty()) {
            const int idx = expect.toInt();
            const QVariantList frames = shell->frames();
            exclusionOK = idx < frames.size()
                && !frames[idx].toMap().value(QStringLiteral("included")).toBool();
        }
        // Grab after the queued change signal has delivered, so the shot
        // shows the settled UI (the assertions above already ran).
        QTimer::singleShot(250, engine, [engine, state, exported, depthExported,
                                         wasStale, staleAfterEdit, exclusionOK,
                                         toneKeptPixels, depthBumpedPixels,
                                         fullRes, batchOK] {
            if (!state->shotPath.isEmpty()) {
                const auto roots = engine->rootObjects();
                if (!roots.isEmpty()) {
                    if (auto *window = qobject_cast<QQuickWindow *>(roots.first())) {
                        window->grabWindow().save(state->shotPath);
                    }
                }
            }
            if (!exported) { QCoreApplication::exit(5); return; }
            if (!depthExported) { QCoreApplication::exit(6); return; }
            if (wasStale || !staleAfterEdit) { QCoreApplication::exit(7); return; }
            if (!exclusionOK) { QCoreApplication::exit(8); return; }
            if (!toneKeptPixels || !depthBumpedPixels) {
                QCoreApplication::exit(9);
                return;
            }
            if (!fullRes) { QCoreApplication::exit(10); return; }
            if (!batchOK) { QCoreApplication::exit(11); return; }
            QCoreApplication::exit(0);
        });
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
