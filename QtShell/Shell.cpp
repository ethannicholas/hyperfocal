#include "Shell.h"

#include <QMetaObject>
#include <QVariantMap>

#include "hyperfocal_bridge.h"

#include <QMessageBox>
#include <QPushButton>

namespace {
Shell *liveShell = nullptr;
QByteArray liveLut;    // last-seen curve bytes (16-bit ramp)
int liveLutEpoch = 0;

// Re-read the curve; bump the epoch only on real change so the LUT
// texture doesn't reload on every model tick.
void refreshLut() {
    QByteArray lut(4096 * 2, Qt::Uninitialized);
    if (!hf_tone_lut(reinterpret_cast<uint16_t *>(lut.data()), 4096)) return;
    if (lut != liveLut) {
        liveLut = lut;
        ++liveLutEpoch;
    }
}

// HFQT_AUTOCONFIRM=1 answers every confirm with its default button and
// swallows notices — the headless hook the selftest uses (the native
// suite's HYPERFOCAL_AUTOCONFIRM, mirrored).
int shellConfirm(const char *message, const char *informative,
                 const char *confirmTitle, const char *cancelTitle,
                 int warning, void *) {
    if (qEnvironmentVariableIsSet("HFQT_AUTOCONFIRM")) return 1;
    QMessageBox box(warning ? QMessageBox::Warning : QMessageBox::Question,
                    QString::fromUtf8(message), QString::fromUtf8(message));
    box.setInformativeText(QString::fromUtf8(informative));
    QAbstractButton *confirm = box.addButton(QString::fromUtf8(confirmTitle),
                                             QMessageBox::AcceptRole);
    box.addButton(QString::fromUtf8(cancelTitle), QMessageBox::RejectRole);
    box.exec();
    return box.clickedButton() == confirm ? 1 : 0;
}

void shellNotify(const char *message, const char *informative, int warning,
                 void *) {
    if (qEnvironmentVariableIsSet("HFQT_AUTOCONFIRM")) return;
    QMessageBox box(warning ? QMessageBox::Warning : QMessageBox::Information,
                    QString::fromUtf8(message), QString::fromUtf8(message));
    box.setInformativeText(QString::fromUtf8(informative));
    box.exec();
}

void bridgeChanged(void *) {
    // Fires on the main thread; queue the signal so QML never re-enters a
    // half-applied model turn.
    refreshLut();
    if (liveShell) {
        QMetaObject::invokeMethod(liveShell, &Shell::changed,
                                  Qt::QueuedConnection);
    }
}
}  // namespace

Shell::Shell(QObject *parent) : QObject(parent) {
    hf_init();
    refreshLut();
    liveShell = this;
    hf_set_changed_callback(bridgeChanged, nullptr);
    hf_set_dialog_callbacks(shellConfirm, shellNotify, nullptr);
}

Shell::~Shell() {
    hf_set_dialog_callbacks(nullptr, nullptr, nullptr);
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

bool Shell::displayIsData() const { return hf_display_is_data() != 0; }

bool Shell::hasInput() const {
    int32_t w = 0, h = 0;
    return hf_input_size(&w, &h) != 0 && w > 0 && h > 0;
}

QString Shell::inputTitle() const {
    char buffer[512];
    const int n = hf_input_title(buffer, sizeof buffer);
    return QString::fromUtf8(buffer, n);
}

int Shell::selectedFrame() const { return hf_selected_frame(); }

void Shell::selectFrame(int index) { hf_select_frame(index); }

void Shell::setCrop(double x, double y, double w, double h, double angle) {
    hf_set_crop(x, y, w, h, angle);
}

QRectF Shell::displayCrop() const {
    double x = 0, y = 0, w = 0, h = 0, angle = 0;
    if (!hf_display_crop(&x, &y, &w, &h, &angle)) return QRectF();
    return QRectF(x, y, w, h);
}

double Shell::displayCropAngle() const {
    double x = 0, y = 0, w = 0, h = 0, angle = 0;
    hf_display_crop(&x, &y, &w, &h, &angle);
    return angle;
}
int Shell::lutEpoch() const { return liveLutEpoch; }

QByteArray Shell::currentLut() { return liveLut; }

bool Shell::depthMode() const { return hf_output_depth() != 0; }

void Shell::setDepthMode(bool depth) {
    if (depth != (hf_output_depth() != 0)) hf_set_output_depth(depth ? 1 : 0);
}

QVariantList Shell::stacks() const {
    // Rebuilt wholesale per change signal, like frames() — dev-shell scale.
    QVariantList list;
    const int count = hf_stack_count();
    list.reserve(count);
    char text[512];
    for (int i = 0; i < count; ++i) {
        QVariantMap row;
        int n = hf_stack_name(i, text, sizeof text);
        row.insert(QStringLiteral("name"), QString::fromUtf8(text, n));
        row.insert(QStringLiteral("enabled"), hf_stack_enabled(i) != 0);
        row.insert(QStringLiteral("status"), hf_stack_status(i));
        n = hf_stack_failure(i, text, sizeof text);
        row.insert(QStringLiteral("failure"), QString::fromUtf8(text, n));
        row.insert(QStringLiteral("frameCount"), hf_stack_frame_count(i));
        list.append(row);
    }
    return list;
}

int Shell::selectedStack() const { return hf_stack_selected(); }
int Shell::pendingStackCount() const { return hf_pending_stack_count(); }

bool Shell::selectStack(int index) { return hf_select_stack(index) != 0; }

void Shell::setStackEnabled(int index, bool enabled) {
    hf_set_stack_enabled(index, enabled ? 1 : 0);
}

bool Shell::fuseEnabledStacks() { return hf_fuse_enabled_stacks() != 0; }

QVariantList Shell::frames() const {
    // Rebuilt wholesale per change signal — fine at dev-shell scale; the
    // production shell gets a QAbstractListModel over the same calls.
    QVariantList list;
    const int count = hf_frame_count();
    list.reserve(count);
    char name[512];
    for (int i = 0; i < count; ++i) {
        const int n = hf_frame_name(i, name, sizeof name);
        QVariantMap row;
        row.insert(QStringLiteral("name"), QString::fromUtf8(name, n));
        row.insert(QStringLiteral("included"), hf_frame_included(i) != 0);
        list.append(row);
    }
    return list;
}

bool Shell::hasDisplay() const {
    int32_t w = 0, h = 0;
    return hf_display_size(&w, &h) != 0 && w > 0 && h > 0;
}

int Shell::displayEpoch() const { return hf_display_epoch(); }

int Shell::displayWidth() const {
    int32_t w = 0, h = 0;
    hf_display_size(&w, &h);
    return w;
}

int Shell::displayHeight() const {
    int32_t w = 0, h = 0;
    hf_display_size(&w, &h);
    return h;
}

double Shell::slider(const QString &id) const {
    return hf_slider(id.toUtf8().constData());
}

void Shell::setSlider(const QString &id, double value) {
    if (value != hf_slider(id.toUtf8().constData()))
        hf_set_slider(id.toUtf8().constData(), value);
}

void Shell::setFrameIncluded(int index, bool included) {
    hf_set_frame_included(index, included ? 1 : 0);
}

bool Shell::openStack(const QUrl &folder) {
    return hf_load_stack(folder.toLocalFile().toUtf8().constData()) != 0;
}

bool Shell::fuse() { return hf_fuse() != 0; }

bool Shell::exportTo(const QUrl &file) {
    // The chosen extension states the intent; don't inherit whatever
    // format was persisted last (the bridge restores the preference
    // after the write, so this never becomes a sticky settings change).
    const QString path = file.toLocalFile();
    const bool tiff = path.endsWith(QStringLiteral(".tif"), Qt::CaseInsensitive)
                   || path.endsWith(QStringLiteral(".tiff"), Qt::CaseInsensitive);
    return hf_export(path.toUtf8().constData(),
                     tiff ? "TIFF (16-bit)" : nullptr) != 0;
}
