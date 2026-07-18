#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQuickWindow>
#include <QTimer>
#include <QUrl>

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
        if (!state->fused) {
            if (shell->canFuse()) {
                state->fused = true;
                shell->fuse();
            }
            return;
        }
        if (shell->isRunning()) {
            state->sawRunning = true;
            return;
        }
        if (!state->sawRunning) return;  // fuse not started yet
        state->done = true;
        shell->setExposure(0.5);  // tone reaches the preview + export
        const bool exported =
            shell->exportTo(QUrl::fromLocalFile(state->outPath));
        if (!state->shotPath.isEmpty()) {
            const auto roots = engine->rootObjects();
            if (!roots.isEmpty()) {
                if (auto *window = qobject_cast<QQuickWindow *>(roots.first())) {
                    window->grabWindow().save(state->shotPath);
                }
            }
        }
        QCoreApplication::exit(exported ? 0 : 5);
    });
    poll->start(200);

    // Backstop: a hung fuse must fail the test, not wedge it.
    QTimer::singleShot(180000, engine, [] { QCoreApplication::exit(2); });
}

}  // namespace

int main(int argc, char *argv[]) {
    QGuiApplication app(argc, argv);
    QQmlApplicationEngine engine;
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed,
                     &app, [] { QCoreApplication::exit(1); },
                     Qt::QueuedConnection);
    engine.loadFromModule("Hyperfocal", "Main");

    const QStringList args = app.arguments();
    SelfTest state;
    if (args.size() >= 4 && args[1] == QStringLiteral("--selftest")) {
        state.stackDir = args[2];
        state.outPath = args[3];
        state.shotPath = args.size() >= 5 ? args[4] : QString();
        // After the QML engine settles, so the Shell singleton exists.
        QTimer::singleShot(0, &engine, [&engine, &state] {
            runSelfTest(&engine, &state);
        });
    }
    return app.exec();
}
