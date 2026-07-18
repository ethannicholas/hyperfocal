#include "Shell.h"

#include <QMetaObject>
#include <vector>

#include "hyperfocal_bridge.h"

namespace {
Shell *liveShell = nullptr;

void bridgeChanged(void *) {
    // Fires on the main thread; queue the signal so QML never re-enters a
    // half-applied model turn.
    if (liveShell) {
        QMetaObject::invokeMethod(liveShell, &Shell::changed,
                                  Qt::QueuedConnection);
    }
}
}  // namespace

Shell::Shell(QObject *parent) : QObject(parent) {
    hf_init();
    liveShell = this;
    hf_set_changed_callback(bridgeChanged, nullptr);
}

Shell::~Shell() {
    hf_set_changed_callback(nullptr, nullptr);
    liveShell = nullptr;
}

bool Shell::canFuse() const { return hf_can_fuse() != 0; }
bool Shell::isRunning() const { return hf_is_running() != 0; }
double Shell::stageFraction() const { return hf_stage_fraction(); }

QString Shell::stageText() const {
    char buffer[256];
    const int n = hf_stage_text(buffer, sizeof buffer);
    return QString::fromUtf8(buffer, n);
}

double Shell::exposure() const { return hf_tone_exposure(); }

void Shell::setExposure(double ev) {
    if (ev != hf_tone_exposure()) hf_set_tone_exposure(ev);
}

bool Shell::openStack(const QUrl &folder) {
    return hf_load_stack(folder.toLocalFile().toUtf8().constData()) != 0;
}

bool Shell::fuse() { return hf_fuse() != 0; }

bool Shell::exportTo(const QUrl &file) {
    // The chosen extension states the intent; don't inherit whatever format
    // the native app persisted last (the settings suite is shared until the
    // Phase 3 storage glue isolates it — the bridge restores the user's
    // preference after the write).
    const QString path = file.toLocalFile();
    const bool tiff = path.endsWith(QStringLiteral(".tif"), Qt::CaseInsensitive)
                   || path.endsWith(QStringLiteral(".tiff"), Qt::CaseInsensitive);
    return hf_export(path.toUtf8().constData(),
                     tiff ? "TIFF (16-bit)" : nullptr) != 0;
}
