// Store-media capture channel: the Qt shell's analogue of the macOS app's
// UITestSupport command channel (App/Sources/UITestSupport.swift). The macOS
// side is driven by Scripts/store-media.py, this one by
// Scripts/store-media.ps1, and the two speak the same command vocabulary —
// set-window / set-zoom / set-slider / set-sections / set-retouch /
// get-geometry — so one capture recipe describes both shells rather than two
// unrelated scripts drifting apart.
//
// FILE-BASED, not a socket, deliberately. QLocalServer lives in Qt6::Network:
// windeployqt already stages Qt6Network.dll transitively, but *linking* it
// would turn a tool no user ever runs into a declared dependency of the
// shipped payload. The macOS channel already returns its results as files in
// a staging directory, so a polled directory is the same shape, not a lesser
// one — and capture is not latency-sensitive.
//
// Inert unless HFQT_COMMAND_DIR names a directory, exactly as UITestSupport
// is inert without HYPERFOCAL_UITEST.
//
// Protocol. The driver writes <dir>/cmd-<n>.json and the shell answers with
// <dir>/r<n>.json. Both sides write to a temporary name and rename into
// place: a rename is atomic on both NTFS and POSIX, and without it the poller
// reliably reads a half-written file (a plain write is not one syscall).
// Every reply carries "ok": 1 or 0, and "detail" when it is 0.
#ifndef COMMANDCHANNEL_H
#define COMMANDCHANNEL_H

#include <QCoreApplication>
#include <QDir>
#include <QEventLoop>
#include <QFile>
#include <QFileInfo>
#include <QImage>
#include <QJsonDocument>
#include <QJsonObject>
#include <QPointF>
#include <QQmlApplicationEngine>
#include <QQuickWindow>
#include <QScreen>
#include <QSet>
#include <QString>
#include <QTimer>

#include "PaneItem.h"
#include "Shell.h"

namespace CommandChannel {

struct State {
    QDir dir;
    QQmlApplicationEngine *engine = nullptr;
    QSet<QString> handled;
    bool busy = false;
};

inline Shell *shellOf(QQmlApplicationEngine *engine) {
    return engine->singletonInstance<Shell *>("Hyperfocal", "Shell");
}

inline QQuickWindow *windowOf(QQmlApplicationEngine *engine) {
    const auto roots = engine->rootObjects();
    if (roots.isEmpty()) return nullptr;
    return qobject_cast<QQuickWindow *>(roots.first());
}

inline PaneItem *paneOf(QQmlApplicationEngine *engine, const QString &name) {
    const auto roots = engine->rootObjects();
    if (roots.isEmpty()) return nullptr;
    return roots.first()->findChild<PaneItem *>(name);
}

inline QJsonObject fail(const QString &why) {
    QJsonObject r;
    r["ok"] = 0;
    r["detail"] = why;
    return r;
}

// A window grab, settled. Tile fetches and the queued bridge->tick->QML
// chain both land over several frames, so a single grab routinely catches a
// half-painted pane; the selftest's zoom cycle learned the same lesson.
// Settled = two consecutive identical grabs.
inline QImage settledGrab(QQuickWindow *window, int maxTicks = 80) {
    QImage prev, now;
    for (int i = 0; i < maxTicks; ++i) {
        QCoreApplication::processEvents(QEventLoop::AllEvents, 50);
        now = window->grabWindow();
        if (!now.isNull() && now == prev) break;
        prev = now;
    }
    return now;
}

inline QJsonObject geometry(State *state) {
    Shell *shell = shellOf(state->engine);
    QQuickWindow *window = windowOf(state->engine);
    if (!shell || !window) return fail("no shell/window yet");

    QJsonObject r;
    r["ok"] = 1;
    // The same coarse phase vocabulary the macOS channel reports, so the
    // two drivers can share their wait predicates.
    r["phase"] = shell->isRunning()  ? QStringLiteral("running")
                 : shell->hasDisplay() ? QStringLiteral("done")
                 : shell->canFuse()    ? QStringLiteral("loaded")
                                       : QStringLiteral("empty");
    r["running"] = shell->isRunning() ? 1 : 0;
    r["hasDisplay"] = shell->hasDisplay() ? 1 : 0;
    r["stageText"] = shell->stageText();
    r["stageFraction"] = shell->stageFraction();
    r["imageW"] = shell->displayWidth();
    r["imageH"] = shell->displayHeight();
    r["windowW"] = window->width();
    r["windowH"] = window->height();
    // Store sizes are in PIXELS; the window is in logical points. Everything
    // the driver validates has to go through this ratio.
    r["dpr"] = window->effectiveDevicePixelRatio();
    // The work area bounds any window that isn't fullscreen, so a capture
    // size larger than this is simply unreachable - the same clamp the macOS
    // driver hits against the Dock. Reported so the driver can say what will
    // fit instead of only what failed.
    if (QScreen *screen = window->screen()) {
        r["availW"] = screen->availableSize().width();
        r["availH"] = screen->availableSize().height();
    }
    r["retouch"] = shell->retouchMode() ? 1 : 0;
    r["canRetouch"] = shell->canRetouch() ? 1 : 0;
    r["canPaint"] = shell->retouchCanPaint() ? 1 : 0;
    r["sourceLoading"] = shell->retouchSourceLoading() ? 1 : 0;
    r["sourceName"] = shell->retouchSourceName();
    r["sourceStatus"] = shell->retouchSourceStatus();
    if (PaneItem *pane = paneOf(state->engine,
                                QStringLiteral("outputPaneItem"))) {
        const QPointF origin = pane->mapToScene(QPointF(0, 0));
        r["paneX"] = origin.x();
        r["paneY"] = origin.y();
        r["paneW"] = pane->width();
        r["paneH"] = pane->height();
        r["displayScale"] = pane->displayScale();
    }
    return r;
}

inline QJsonObject execute(State *state, const QJsonObject &cmd) {
    const QString action = cmd.value(QStringLiteral("action")).toString();
    Shell *shell = shellOf(state->engine);
    QQuickWindow *window = windowOf(state->engine);
    if (!shell || !window) return fail("no shell/window yet");
    auto num = [&cmd](const char *key, double fallback = 0.0) {
        return cmd.value(QLatin1String(key)).toDouble(fallback);
    };

    if (action == QLatin1String("get-geometry")) return geometry(state);

    if (action == QLatin1String("set-window")) {
        const int w = int(num("w")), h = int(num("h"));
        if (w <= 0 || h <= 0) return fail("set-window needs w and h");
        window->setVisibility(QWindow::Windowed);
        window->resize(w, h);
        QCoreApplication::processEvents();
        if (window->width() != w || window->height() != h) {
            QString avail;
            if (QScreen *screen = window->screen()) {
                avail = QStringLiteral("; this screen's work area is %1x%2 pt")
                            .arg(screen->availableSize().width())
                            .arg(screen->availableSize().height());
            }
            return fail(QStringLiteral("window is %1x%2, asked for %3x%4 - "
                                       "windows are clamped to the work area%5")
                            .arg(window->width()).arg(window->height())
                            .arg(w).arg(h).arg(avail));
        }
        QJsonObject r;
        r["ok"] = 1;
        return r;
    }

    if (action == QLatin1String("set-zoom")) {
        PaneItem *pane = paneOf(state->engine,
                                QStringLiteral("outputPaneItem"));
        if (!pane) return fail("no output pane");
        // Absolute image scale (1 = 1:1), the zoom bar's currency and what
        // the macOS channel's set-zoom means.
        pane->setAbsoluteScale(num("scale", 1.0));
        if (cmd.contains(QStringLiteral("cx"))
            && cmd.contains(QStringLiteral("cy"))) {
            pane->centerOn(QPointF(num("cx"), num("cy")));
        }
        QJsonObject r;
        r["ok"] = 1;
        r["displayScale"] = pane->displayScale();
        return r;
    }

    if (action == QLatin1String("set-slider")) {
        const QString id = cmd.value(QStringLiteral("id")).toString();
        if (id.isEmpty()) return fail("set-slider needs id");
        shell->setSlider(id, num("value"));
        QJsonObject r;
        r["ok"] = 1;
        r["value"] = shell->slider(id);
        return r;
    }

    if (action == QLatin1String("set-sections")) {
        // Absolute, not a toggle: name the sections that must end up
        // collapsed and the rest are expanded, so a capture is idempotent
        // however the settings were left.
        const QString want = cmd.value(QStringLiteral("collapsed")).toString();
        QSet<QString> target;
        const QStringList parts = want.split(QLatin1Char(','),
                                             Qt::SkipEmptyParts);
        for (const QString &p : parts) target.insert(p.trimmed());
        const QStringList known = {QStringLiteral("stack"),
                                   QStringLiteral("fusion"),
                                   QStringLiteral("tone"),
                                   QStringLiteral("retouch"),
                                   QStringLiteral("export")};
        for (const QString &name : known) {
            const bool isCollapsed = shell->collapsedSections().contains(name);
            if (isCollapsed != target.contains(name)) shell->toggleSection(name);
        }
        QJsonObject r;
        r["ok"] = 1;
        r["collapsed"] = shell->collapsedSections().join(QLatin1Char(','));
        return r;
    }

    if (action == QLatin1String("fuse")) {
        if (!shell->canFuse()) return fail("nothing to fuse");
        QJsonObject r;
        r["ok"] = shell->fuse() ? 1 : 0;
        return r;
    }

    if (action == QLatin1String("enter-retouch")) {
        // Reports not-ready rather than blocking — the result and its depth
        // plane have to settle first, and the driver polls.
        if (!shell->canRetouch()) return fail("retouch not ready");
        QJsonObject r;
        r["ok"] = shell->enterRetouch() ? 1 : 0;
        return r;
    }

    if (action == QLatin1String("set-retouch")) {
        const QString source = cmd.value(QStringLiteral("source")).toString();
        // Kinds per hf_set_retouch_source_kind: 0 frame, 1 pmax, 2 dmap.
        const int kind = source == QLatin1String("pmax")   ? 1
                         : source == QLatin1String("dmap") ? 2
                         : source == QLatin1String("frame") ? 0
                                                            : -1;
        if (kind < 0) return fail("set-retouch source must be frame/pmax/dmap");
        shell->setRetouchSourceKind(kind);
        QJsonObject r;
        r["ok"] = 1;
        return r;
    }

    if (action == QLatin1String("set-depth")) {
        const bool want = num("on") != 0;
        if (want && !shell->hasDepth()) return fail("no depth preview");
        shell->setDepthMode(want);
        QJsonObject r;
        r["ok"] = 1;
        return r;
    }

    if (action == QLatin1String("set-hover")) {
        // Image pixels, the same space RetouchOverlay hands retouchHover
        // after pane->mapToImage. This is what draws the brush circle: the
        // Qt shot needs no real pointer, unlike the macOS one, because the
        // circle is a QML overlay that grabWindow captures.
        shell->retouchHover(num("x"), num("y"));
        QJsonObject r;
        r["ok"] = 1;
        return r;
    }

    if (action == QLatin1String("clear-hover")) {
        shell->retouchHoverClear();
        QJsonObject r;
        r["ok"] = 1;
        return r;
    }

    if (action == QLatin1String("grab")) {
        const QString path = cmd.value(QStringLiteral("path")).toString();
        if (path.isEmpty()) return fail("grab needs path");
        const QImage shot = settledGrab(window);
        if (shot.isNull()) return fail("grabWindow returned nothing");
        if (!shot.save(path, "PNG")) return fail("could not write " + path);
        QJsonObject r;
        r["ok"] = 1;
        r["w"] = shot.width();
        r["h"] = shot.height();
        return r;
    }

    if (action == QLatin1String("quit")) {
        QJsonObject r;
        r["ok"] = 1;
        QTimer::singleShot(0, qApp, [] { QCoreApplication::quit(); });
        return r;
    }

    return fail("unknown action: " + action);
}

inline void reply(State *state, const QString &token, const QJsonObject &r) {
    const QString finalPath = state->dir.filePath("r" + token + ".json");
    const QString tempPath = finalPath + ".part";
    QFile f(tempPath);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate)) return;
    f.write(QJsonDocument(r).toJson(QJsonDocument::Compact));
    f.close();
    QFile::remove(finalPath);
    QFile::rename(tempPath, finalPath);
}

inline void poll(State *state) {
    // Re-entrancy guard: execute() spins the event loop (settledGrab and
    // set-window both processEvents), so this timer can fire again inside a
    // command and run it twice.
    if (state->busy) return;
    state->busy = true;
    // QDir caches its directory listing, and this one was built when the
    // staging directory was still empty — without refresh() the poller reads
    // that empty snapshot forever and no command is ever seen.
    state->dir.refresh();
    const QStringList pending =
        state->dir.entryList({QStringLiteral("cmd-*.json")},
                             QDir::Files, QDir::Name);
    for (const QString &name : pending) {
        if (state->handled.contains(name)) continue;
        state->handled.insert(name);
        QFile f(state->dir.filePath(name));
        if (!f.open(QIODevice::ReadOnly)) continue;
        const QJsonObject cmd =
            QJsonDocument::fromJson(f.readAll()).object();
        f.close();
        // cmd-7.json -> r7.json
        QString token = QFileInfo(name).completeBaseName();
        token.remove(0, 4);
        reply(state, token, execute(state, cmd));
    }
    state->busy = false;
}

// Call once, after the QML engine has loaded, from main().
inline void installIfRequested(QQmlApplicationEngine *engine) {
    const QString dir = QString::fromLocal8Bit(qgetenv("HFQT_COMMAND_DIR"));
    if (dir.isEmpty()) return;
    if (!QDir().mkpath(dir)) {
        qWarning() << "command channel: cannot create" << dir;
        return;
    }
    auto *state = new State;
    state->dir = QDir(dir);
    state->engine = engine;
    auto *timer = new QTimer(engine);
    QObject::connect(timer, &QTimer::timeout, engine,
                     [state] { poll(state); });
    timer->start(100);
    // A "ready" marker, not a log line: the shell is a GUI-subsystem binary
    // on Windows, so qInfo() reaches no console the driver could read, and a
    // channel that failed to start is otherwise indistinguishable from an app
    // that is merely slow to ingest. The driver waits for this file.
    QFile marker(state->dir.filePath(QStringLiteral("ready")));
    if (marker.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        marker.write(QByteArrayLiteral("1"));
        marker.close();
    }
}

}  // namespace CommandChannel

#endif  // COMMANDCHANNEL_H
