#include "Shell.h"

#include <QMetaObject>
#include <QVariantMap>

#include "hyperfocal_bridge.h"

#include <QComboBox>
#include <QCursor>
#include <QDesktopServices>
#include <QFileDialog>
#include <QGridLayout>
#include <QHash>
#include <QImage>
#include <QLabel>
#include <QMutex>
#include <QMutexLocker>
#include <QIcon>
#include <QMessageBox>
#include <QPainter>
#include <QPixmap>
#include <QQuickItem>
#include <QTransform>
#include <QUrl>
#include <QVector>
#include <algorithm>
#include <utility>
#include <vector>
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
// Alerts carry the app icon like native NSAlerts (the style default
// is a generic severity glyph).
void applyAlertIcon(QMessageBox &box) {
    const QIcon icon(QStringLiteral(":/AppIcon.png"));
    if (!icon.isNull()) box.setIconPixmap(icon.pixmap(48, 48));
}

// AppCore speaks NSAlert's shape: `message` is the short headline,
// `informative` the detail. Qt has no headline slot — it has a window
// title plus body text — so the headline becomes the title and the
// detail becomes the body (QMessageBox's 3-arg ctor is title, text).
// Passing the headline as BOTH (the original mapping) printed it twice:
// once in the title bar, again as the body's first line. Informative is
// never empty from AppCore; the fallback keeps a bare-headline caller
// from producing an empty box.
QString alertBody(const QString &message, const QString &informative) {
    return informative.isEmpty() ? message : informative;
}

// Static UI text shared verbatim with the native app (AppCore.UIStrings) —
// used both by Shell::uiString (QML call sites) and directly by the free
// functions below (dialog buttons built outside any Shell method).
QString bridgeUIString(const QString &key) {
    char buffer[1024];
    const int n = hf_ui_string(key.toUtf8().constData(), buffer, sizeof buffer);
    return QString::fromUtf8(buffer, n);
}

// Option combos show translated labels but persist enum rawValues, so the
// two lists are kept parallel and selection is by INDEX, never by text —
// matching a translated label against a raw value would silently reset the
// popup to its first entry in every non-English run. Unknown/absent raw
// values fall back to the first entry, as they did before.
int selectRaw(const QStringList &rawValues, const QString &current) {
    const qsizetype i = rawValues.indexOf(current);
    return i < 0 ? 0 : int(i);
}

int shellConfirm(const char *message, const char *informative,
                 const char *confirmTitle, const char *cancelTitle,
                 int warning, void *) {
    if (qEnvironmentVariableIsSet("HFQT_AUTOCONFIRM")) return 1;
    QMessageBox box(warning ? QMessageBox::Warning : QMessageBox::Question,
                    QString::fromUtf8(message),
                    alertBody(QString::fromUtf8(message), QString::fromUtf8(informative)));
    applyAlertIcon(box);
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
                    QString::fromUtf8(message),
                    alertBody(QString::fromUtf8(message), QString::fromUtf8(informative)));
    applyAlertIcon(box);
    box.exec();
}

void shellGuideDownload(const char *message, const char *informative,
                        const char *url, void *) {
    QMessageBox box(QMessageBox::Warning, QString::fromUtf8(message),
                    alertBody(QString::fromUtf8(message), QString::fromUtf8(informative)));
    applyAlertIcon(box);
    QAbstractButton *download =
        box.addButton(QObject::tr("Open Download Page"), QMessageBox::AcceptRole);
    box.addButton(bridgeUIString("cancel"), QMessageBox::RejectRole);
    box.exec();
    if (box.clickedButton() == download)
        QDesktopServices::openUrl(QUrl(QString::fromUtf8(url)));
}

void bridgeChanged(void *) {
    // Fires on the main thread; queue the refresh so QML never re-enters
    // a half-applied model turn.
    refreshLut();
    if (liveShell) {
        QMetaObject::invokeMethod(liveShell, &Shell::refreshFromBridge,
                                  Qt::QueuedConnection);
    }
}
}  // namespace

static QList<int> readSelectedFrames();

Shell::Shell(QObject *parent) : QObject(parent) {
    hf_init();
    refreshLut();
    liveShell = this;
    hf_set_changed_callback(bridgeChanged, nullptr);
    hf_set_dialog_callbacks(shellConfirm, shellNotify, nullptr);
    hf_set_guide_callback(shellGuideDownload, nullptr);
    refreshFromBridge();
}

void Shell::refreshFromBridge() {
    emit tick();
    const bool running = hf_is_running() != 0;
    const double fraction = hf_stage_fraction();
    const QString stage = stageText() + QStringLiteral("\x1f") + stageEta();
    if (running != cachedRunning_ || fraction != cachedFraction_
        || stage != cachedStage_) {
        cachedRunning_ = running;
        cachedFraction_ = fraction;
        cachedStage_ = stage;
        emit progressChanged();
    }
    QVariantList frames = buildFrames();
    const int selectedFrame = hf_selected_frame();
    QList<int> selectedFrames = readSelectedFrames();
    if (frames != cachedFrames_ || selectedFrame != cachedSelectedFrame_
        || selectedFrames != cachedSelectedFrames_) {
        cachedFrames_ = std::move(frames);
        cachedSelectedFrame_ = selectedFrame;
        cachedSelectedFrames_ = std::move(selectedFrames);
        emit framesChanged();
    }
    QVariantList stacks = buildStacks();
    const int selectedStack = hf_stack_selected();
    const int pending = hf_pending_stack_count();
    const bool fuseable = hf_can_fuse() != 0;
    if (stacks != cachedStacks_ || selectedStack != cachedSelectedStack_
        || pending != cachedPending_ || fuseable != cachedCanFuse_) {
        cachedStacks_ = std::move(stacks);
        cachedSelectedStack_ = selectedStack;
        cachedPending_ = pending;
        cachedCanFuse_ = fuseable;
        emit stacksChanged();
    }
    QVariantList print = fingerprint();
    if (print != cachedFingerprint_) {
        cachedFingerprint_ = std::move(print);
        emit changed();
    }
}

/// Everything on the coarse changed() signal, gathered for the diff —
/// cheap scalar reads, so one pass per callback costs little while
/// sparing every binding re-evaluation on progress ticks.
QVariantList Shell::fingerprint() const {
    return {exposure(), depthMode(), displayIsData(), hasDepth(), hasInput(),
            inputLoading(), inputTitle(), displayCrop(), displayCropAngle(),
            toneNeutral(), fusionDefault(), hasDisplay(), projectPath(),
            hasUnsavedWork(), canUndo(), canRedo(), undoTitle(), redoTitle(),
            lutEpoch(), exportFormat(), exportColorSpace(),
            animationStrength(), cropMode(), canCrop(), cropAspect(),
            retouchMode(), canRetouch(), retouchHasEdits(),
            retouchSourceKind(), retouchSourceName(),
            retouchSourceLoading(), retouchSourceError(),
            retouchSourceStatus(), collapsedSections(),
            cropAspectRatio(), cropPortrait(), editCrop(), editCropAngle(),
            slider(QStringLiteral("fusion.slider.sharpness")),
            slider(QStringLiteral("fusion.slider.noise-floor")),
            slider(QStringLiteral("fusion.slider.median-radius")),
            slider(QStringLiteral("fusion.slider.blend-radius")),
            slider(QStringLiteral("tone.slider.contrast")),
            slider(QStringLiteral("tone.slider.highlights")),
            slider(QStringLiteral("tone.slider.shadows")),
            slider(QStringLiteral("tone.slider.whites")),
            slider(QStringLiteral("tone.slider.blacks"))};
}

Shell::~Shell() {
    hf_set_guide_callback(nullptr, nullptr);
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

QString Shell::stageEta() const {
    char buffer[128];
    const int n = hf_stage_eta(buffer, sizeof buffer);
    return QString::fromUtf8(buffer, n);
}

QString Shell::suggestedProjectName() const {
    const QVariantList list = stacks();
    // Only the stem is translated; the extension identifies the format.
    if (list.isEmpty()) return tr("Project") + QStringLiteral(".hyperfocal");
    return list.first().toMap().value(QStringLiteral("name")).toString()
        + QStringLiteral(".hyperfocal");
}

void Shell::exportAnimationInteractive() {
    QFileDialog dialog(nullptr, tr("Export Rocking Animation"));
    dialog.setOption(QFileDialog::DontUseNativeDialog);
    dialog.setAcceptMode(QFileDialog::AcceptSave);
    dialog.setFileMode(QFileDialog::AnyFile);
    // Every option list here is a persisted enum rawValue on the model side
    // (AnimationFormat/Duration/Path/Strength). The raw list is what crosses
    // the bridge; the parallel *Labels list is what the user reads. Never
    // write a label back — that would persist a translated rawValue.
    //
    // H.264 additionally needs AVFoundation: off Apple the engine writes GIF
    // only (RockingAnimation's non-Apple path), so don't offer a container the
    // export would then have to refuse.
    QStringList formats, formatLabels, suffixes;
#ifdef Q_OS_MACOS
    formats << QStringLiteral("MP4 (H.264)");
    formatLabels << tr("MP4 (H.264)");
    suffixes << QStringLiteral("mp4");
#endif
    formats << QStringLiteral("GIF (loops automatically)");
    formatLabels << tr("GIF (loops automatically)");
    suffixes << QStringLiteral("gif");
    QStringList filters;
    for (qsizetype i = 0; i < formats.size(); ++i)
        filters << formatLabels[i] + " (*." + suffixes[i] + ")";
    dialog.setNameFilters(filters);
    QString currentFormat;
    {
        char buffer[64];
        currentFormat = QString::fromUtf8(
            buffer, hf_animation_format(buffer, sizeof buffer));
    }
    dialog.selectNameFilter(
        filters.value(qMax(qsizetype(0), formats.indexOf(currentFormat))));
    auto applyFormat = [&] {
        const qsizetype i = filters.indexOf(dialog.selectedNameFilter());
        dialog.setDefaultSuffix(
            suffixes.value(qMax(qsizetype(0), i), suffixes.first()));
    };
    applyFormat();
    QObject::connect(&dialog, &QFileDialog::filterSelected, &dialog,
                     [&applyFormat](const QString &) { applyFormat(); });
    // The native accessory's remaining rows.
    const QStringList durations = {
        QStringLiteral("2 seconds"), QStringLiteral("3 seconds"),
        QStringLiteral("4 seconds"), QStringLiteral("6 seconds")};
    auto *duration = new QComboBox(&dialog);
    duration->addItems({tr("2 seconds"), tr("3 seconds"),
                        tr("4 seconds"), tr("6 seconds")});
    {
        char buffer[64];
        duration->setCurrentIndex(selectRaw(durations, QString::fromUtf8(
            buffer, hf_animation_duration(buffer, sizeof buffer))));
    }
    const QStringList paths = {QStringLiteral("Rock left–right"),
                               QStringLiteral("Rock up–down"),
                               QStringLiteral("Circle")};
    auto *path = new QComboBox(&dialog);
    path->addItems({tr("Rock left–right"), tr("Rock up–down"), tr("Circle")});
    {
        char buffer[64];
        path->setCurrentIndex(selectRaw(paths, QString::fromUtf8(
            buffer, hf_animation_path(buffer, sizeof buffer))));
    }
    const QStringList strengths = {QStringLiteral("Subtle"),
                                   QStringLiteral("Medium"),
                                   QStringLiteral("Strong")};
    auto *strength = new QComboBox(&dialog);
    strength->addItems({tr("Subtle"), tr("Medium"), tr("Strong")});
    strength->setCurrentIndex(selectRaw(strengths, animationStrength()));
    if (auto *grid = qobject_cast<QGridLayout *>(dialog.layout())) {
        int row = grid->rowCount();
        const std::pair<QString, QComboBox *> rows[] = {
            {bridgeUIString("duration"), duration}, {bridgeUIString("path"), path},
            {bridgeUIString("strength"), strength}};
        for (const auto &[label, combo] : rows) {
            grid->addWidget(new QLabel(label, &dialog),
                            row, 0, Qt::AlignRight);
            grid->addWidget(combo, row, 1);
            ++row;
        }
    }
    if (dialog.exec() != QDialog::Accepted || dialog.selectedFiles().isEmpty())
        return;
    hf_set_animation_format(
        formats.value(qMax(qsizetype(0),
                           filters.indexOf(dialog.selectedNameFilter())))
            .toUtf8().constData());
    hf_set_animation_duration(
        durations.value(duration->currentIndex()).toUtf8().constData());
    hf_set_animation_path(
        paths.value(path->currentIndex()).toUtf8().constData());
    setAnimationStrength(strengths.value(strength->currentIndex()));
    hf_export_animation(
        dialog.selectedFiles().first().toUtf8().constData());
}

double Shell::exposure() const { return hf_tone_exposure(); }

void Shell::setExposure(double ev) {
    if (ev != hf_tone_exposure()) hf_set_tone_exposure(ev);
}

bool Shell::displayIsData() const { return hf_display_is_data() != 0; }

bool Shell::hasDepth() const { return hf_has_depth() != 0; }

bool Shell::hasInput() const {
    int32_t w = 0, h = 0;
    return hf_input_size(&w, &h) != 0 && w > 0 && h > 0;
}

bool Shell::inputLoading() const {
    return hf_input_loading() != 0;
}

QString Shell::inputTitle() const {
    char buffer[512];
    const int n = hf_input_title(buffer, sizeof buffer);
    return QString::fromUtf8(buffer, n);
}

QString Shell::inputError() const {
    // Roomier than inputTitle's: this carries the DNG-Converter notice, which
    // is a sentence plus a URL rather than a file name.
    char buffer[1024];
    const int n = hf_input_error(buffer, sizeof buffer);
    return QString::fromUtf8(buffer, n);
}

int Shell::selectedFrame() const { return hf_selected_frame(); }

// Two-call sizing against the bridge: count first, then fill. Ascending.
static QList<int> readSelectedFrames() {
    const int n = hf_selected_frames(nullptr, 0);
    QList<int> out;
    if (n <= 0)
        return out;
    out.resize(n);
    hf_selected_frames(reinterpret_cast<int32_t *>(out.data()), n);
    return out;
}

QList<int> Shell::selectedFrames() const { return readSelectedFrames(); }

void Shell::selectFrame(int index) { hf_select_frame(index); }

void Shell::selectStackFrame(int stack, int frame) {
    hf_select_stack_frame(stack, frame);
}

void Shell::setCrop(double x, double y, double w, double h, double angle) {
    hf_set_crop(x, y, w, h, angle);
}

bool Shell::cropMode() const { return hf_crop_mode() != 0; }

bool Shell::retouchMode() const { return hf_retouch_mode() != 0; }
bool Shell::canRetouch() const { return hf_can_retouch() != 0; }
bool Shell::retouchHasEdits() const { return hf_retouch_has_edits() != 0; }
int Shell::retouchSourceKind() const { return hf_retouch_source_kind(); }
void Shell::setRetouchSourceKind(int kind) { hf_set_retouch_source_kind(kind); }
bool Shell::enterRetouch() { return hf_enter_retouch() != 0; }
bool Shell::exitRetouch() { return hf_exit_retouch() != 0; }
bool Shell::revertRetouch() { return hf_revert_retouch() != 0; }
void Shell::retouchStrokeBegin(double x, double y) {
    hf_retouch_stroke_begin(x, y);
}
void Shell::retouchStrokeMove(double x0, double y0, double x1, double y1) {
    hf_retouch_stroke_move(x0, y0, x1, y1);
}
void Shell::retouchStrokeEnd() { hf_retouch_stroke_end(); }
QStringList Shell::collapsedSections() const {
    static const char *const names[] =
        {"stack", "fusion", "tone", "retouch", "export"};
    QStringList out;
    for (const char *n : names)
        if (hf_section_collapsed(n)) out << QString::fromLatin1(n);
    return out;
}
QString Shell::appVersion() const { return QStringLiteral(HFQT_VERSION); }
QString Shell::appBuild() const { return QStringLiteral(HFQT_BUILD); }
void Shell::toggleSection(const QString &name) {
    hf_toggle_section(name.toUtf8().constData());
}
void Shell::retouchHover(double x, double y) { hf_retouch_hover(x, y); }
void Shell::retouchHoverClear() { hf_retouch_hover_clear(); }
QPointF Shell::cursorScreenPos() const { return QCursor::pos(); }
bool Shell::retouchCanPaint() const { return hf_retouch_can_paint() != 0; }

bool Shell::retouchCursorValid() const {
    double x = 0, y = 0;
    return hf_retouch_cursor(&x, &y) != 0;
}

QPointF Shell::retouchCursor() const {
    double x = 0, y = 0;
    hf_retouch_cursor(&x, &y);
    return QPointF(x, y);
}

double Shell::retouchBrushRadius() const { return hf_retouch_brush_radius(); }
void Shell::retouchAdjustBrush(double factor) { hf_retouch_adjust_brush(factor); }
void Shell::retouchCycleSource(int delta) { hf_retouch_cycle_source(delta); }
void Shell::retouchAutoPick() { hf_retouch_auto_pick(); }
void Shell::retouchTogglePmax() { hf_retouch_toggle_pmax(); }
void Shell::retouchToggleDmap() { hf_retouch_toggle_dmap(); }
void Shell::retouchToggleResult() { hf_retouch_toggle_result(); }

QString Shell::retouchSourceName() const {
    char buffer[512];
    return QString::fromUtf8(buffer,
                             hf_retouch_source_name(buffer, sizeof buffer));
}

bool Shell::retouchSourceLoading() const {
    return hf_retouch_source_loading() != 0;
}

QString Shell::retouchSourceError() const {
    char buffer[512];
    return QString::fromUtf8(buffer,
                             hf_retouch_source_error(buffer, sizeof buffer));
}

QString Shell::retouchSourceStatus() const {
    char buffer[256];
    return QString::fromUtf8(buffer,
                             hf_retouch_source_status(buffer, sizeof buffer));
}
bool Shell::canCrop() const { return hf_can_crop() != 0; }
namespace {

// The eight rotate cursors, built once from the two glyphs the native crop
// overlay uses (ContentView.swift:1971-2006): a corner arc and an edge arc,
// each re-oriented by an affine map instead of shipping eight bitmaps.
//
// Qt's QTransform takes the same (m11, m12, m21, m22) convention AppKit's
// NSAffineTransformStruct does, so the native table transfers — except that
// AppKit composes it in a y-UP image space and Qt in a y-DOWN one. A map M
// applied y-up equals F·M·F applied y-down (F = diag(1, -1)), i.e. m12 and
// m21 negate. Centered mirrors are unaffected by that; only the two
// transposes (sectors 3 and 7) actually change, and they are written below
// already converted.
const QVector<QCursor> &rotateCursors() {
    static const QVector<QCursor> cursors = [] {
        QVector<QCursor> out;
        const QImage corner(QStringLiteral(":/crop-rotate-0.png"));
        const QImage edge(QStringLiteral(":/crop-rotate-1.png"));
        if (corner.isNull() || edge.isNull()) return out;
        // Rendered at 2x into a 24pt cursor, matching the native size.
        constexpr int kDevice = 48;
        constexpr qreal kHalf = kDevice / 2.0;
        struct Sector { const QImage *glyph; qreal m11, m12, m21, m22; };
        const Sector sectors[8] = {
            {&corner,  1,  0,  0,  1},   // 0 top-left: as drawn
            {&edge,    1,  0,  0,  1},   // 1 top: as drawn
            {&corner, -1,  0,  0,  1},   // 2 top-right: mirror H
            {&edge,    0, -1, -1,  0},   // 3 right: transpose
            {&corner, -1,  0,  0, -1},   // 4 bottom-right: mirror both
            {&edge,    1,  0,  0, -1},   // 5 bottom: mirror V
            {&corner,  1,  0,  0, -1},   // 6 bottom-left: mirror V
            {&edge,    0, -1,  1,  0},   // 7 left: transpose + mirror H
        };
        for (const Sector &s : sectors) {
            QPixmap pm(kDevice, kDevice);
            pm.fill(Qt::transparent);
            QPainter p(&pm);
            p.setRenderHint(QPainter::SmoothPixmapTransform);
            p.setTransform(QTransform(
                s.m11, s.m12, s.m21, s.m22,
                kHalf - (s.m11 * kHalf + s.m21 * kHalf),
                kHalf - (s.m12 * kHalf + s.m22 * kHalf)));
            p.drawImage(QRect(0, 0, kDevice, kDevice), *s.glyph);
            p.end();
            pm.setDevicePixelRatio(2.0);
            out.append(QCursor(pm, kDevice / 4, kDevice / 4));   // hotspot: center, in points
        }
        return out;
    }();
    return cursors;
}

} // namespace

void Shell::setCursorShape(QQuickItem *item, int shape) {
    if (!item) return;
    item->setCursor(QCursor(static_cast<Qt::CursorShape>(shape)));
}

void Shell::setRotateCursor(QQuickItem *item, int sector) {
    if (!item) return;
    const QVector<QCursor> &cursors = rotateCursors();
    if (cursors.isEmpty()) {          // glyphs missing from resources
        item->setCursor(QCursor(Qt::CrossCursor));
        return;
    }
    item->setCursor(cursors.at(((sector % 8) + 8) % 8));
}

bool Shell::beginCrop() { return hf_begin_crop() != 0; }
bool Shell::acceptCrop() { return hf_accept_crop() != 0; }
bool Shell::cancelCrop() { return hf_cancel_crop() != 0; }
bool Shell::toggleCropOrientation() { return hf_toggle_crop_orientation() != 0; }
double Shell::cropAspectRatio() const { return hf_crop_aspect_ratio(); }
bool Shell::cropPortrait() const { return hf_crop_portrait() != 0; }

QString Shell::cropAspect() const {
    char buffer[64];
    return QString::fromUtf8(buffer, hf_crop_aspect(buffer, sizeof buffer));
}

void Shell::setCropAspect(const QString &name) {
    hf_set_crop_aspect(name.toUtf8().constData());
}

QRectF Shell::editCrop() const {
    double x = 0, y = 0, w = 0, h = 0, angle = 0;
    if (!hf_edit_crop(&x, &y, &w, &h, &angle)) return QRectF();
    return QRectF(x, y, w, h);
}

double Shell::editCropAngle() const {
    double x = 0, y = 0, w = 0, h = 0, angle = 0;
    hf_edit_crop(&x, &y, &w, &h, &angle);
    return angle;
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

// Stack thumbnails, keyed by their bridge token. Filled by buildStacks on
// the main thread (the only place bridge calls are legal), read by
// StackThumbProvider on QtQuick's pixmap-reader thread — hence the mutex.
static QHash<qlonglong, QImage> thumbCache;
static QMutex thumbCacheMutex;

QImage Shell::thumbnailForToken(qlonglong token) {
    QMutexLocker lock(&thumbCacheMutex);
    return thumbCache.value(token);
}

bool Shell::depthMode() const { return hf_output_depth() != 0; }

void Shell::setDepthMode(bool depth) {
    if (depth != (hf_output_depth() != 0)) hf_set_output_depth(depth ? 1 : 0);
}

QVariantList Shell::stacks() const { return cachedStacks_; }

QVariantList Shell::buildStacks() const {
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
        n = hf_stack_order_warning(i, text, sizeof text);
        row.insert(QStringLiteral("orderWarning"), QString::fromUtf8(text, n));
        row.insert(QStringLiteral("frameCount"), hf_stack_frame_count(i));
        row.insert(QStringLiteral("expanded"), hf_stack_expanded(i) != 0);
        // Nonzero once the middle-frame thumbnail is ready; the call also
        // kicks its background generation, so refreshing the stacks list IS
        // the request. Baked into the image URL as a cache-buster, and the
        // pixels are copied into the provider cache here, on the main
        // thread, because the provider itself must not touch the bridge.
        const qlonglong thumbToken = qlonglong(hf_stack_thumbnail_token(i));
        row.insert(QStringLiteral("thumbToken"), thumbToken);
        if (thumbToken != 0) {
            QMutexLocker lock(&thumbCacheMutex);
            if (!thumbCache.contains(thumbToken)) {
                // Sized by asking, not by a constant: the bridge reports
                // the thumbnail's dimensions even when the buffer is too
                // small, so a bigger model-side thumbnail (AppModel.
                // stackThumbnailMaxSide) grows the buffer instead of
                // silently failing forever — a fixed 96×96 buffer here is
                // exactly how the shell lost its thumbnails when the edge
                // doubled to 192.
                static QByteArray buffer(192 * 192 * 4, Qt::Uninitialized);
                int32_t tw = 0, th = 0;
                bool ok = hf_stack_thumbnail(i,
                                             reinterpret_cast<uint8_t *>(buffer.data()),
                                             int32_t(buffer.size()), &tw, &th) != 0;
                if (!ok && tw > 0 && th > 0
                        && buffer.size() < qsizetype(tw) * th * 4) {
                    buffer.resize(qsizetype(tw) * th * 4);
                    ok = hf_stack_thumbnail(i,
                                            reinterpret_cast<uint8_t *>(buffer.data()),
                                            int32_t(buffer.size()), &tw, &th) != 0;
                }
                if (ok && tw > 0 && th > 0) {
                    thumbCache.insert(thumbToken,
                        QImage(reinterpret_cast<const uchar *>(buffer.constData()),
                               tw, th, tw * 4, QImage::Format_RGBA8888).copy());
                }
            }
        }
        QVariantList stackFrames;
        if (hf_stack_expanded(i) != 0) {
            const int frames = hf_stack_frame_count(i);
            for (int f = 0; f < frames; ++f) {
                QVariantMap frameRow;
                int fn = hf_stack_frame_name(i, f, text, sizeof text);
                frameRow.insert(QStringLiteral("name"),
                                QString::fromUtf8(text, fn));
                frameRow.insert(QStringLiteral("included"),
                                hf_stack_frame_included(i, f) != 0);
                fn = hf_stack_frame_issue(i, f, text, sizeof text);
                frameRow.insert(QStringLiteral("issue"),
                                QString::fromUtf8(text, fn));
                stackFrames.append(frameRow);
            }
        }
        row.insert(QStringLiteral("frames"), stackFrames);
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

void Shell::setStackExpanded(int index, bool expanded) {
    hf_set_stack_expanded(index, expanded ? 1 : 0);
}

void Shell::setStackFrameIncluded(int stack, int frame, bool included) {
    hf_set_stack_frame_included(stack, frame, included ? 1 : 0);
}

bool Shell::fuseEnabledStacks() { return hf_fuse_enabled_stacks() != 0; }

bool Shell::cancelFuse() { return hf_cancel_fuse() != 0; }

int Shell::fusedStackCount() const { return hf_fused_stack_count(); }
bool Shell::canExportAligned() const { return hf_can_export_aligned() != 0; }
bool Shell::canAnimate() const { return hf_can_animate() != 0; }

QString Shell::exportFormat() const {
    char buffer[128];
    return QString::fromUtf8(buffer, hf_export_format(buffer, sizeof buffer));
}

void Shell::setExportFormat(const QString &name) {
    hf_set_export_format(name.toUtf8().constData());
}

QString Shell::fusionAlgorithm() const {
    char buffer[64];
    return QString::fromUtf8(buffer, hf_fusion_algorithm(buffer, sizeof buffer));
}

void Shell::setFusionAlgorithm(const QString &name) {
    hf_set_fusion_algorithm(name.toUtf8().constData());
}

QString Shell::exportColorSpace() const {
    char buffer[128];
    return QString::fromUtf8(buffer,
                             hf_export_color_space(buffer, sizeof buffer));
}

void Shell::setExportColorSpace(const QString &name) {
    hf_set_export_color_space(name.toUtf8().constData());
}

QString Shell::animationStrength() const {
    char buffer[128];
    return QString::fromUtf8(buffer,
                             hf_animation_strength(buffer, sizeof buffer));
}

void Shell::setAnimationStrength(const QString &name) {
    hf_set_animation_strength(name.toUtf8().constData());
}

void Shell::exportInteractive() {
    // Qt's own dialog (not the platform panel) so the accessory rows sit
    // inside it, like the native save panel's Format/Color Space
    // accessory — QFileDialog's grid accepts appended rows only in
    // non-native mode. Standard on Linux/Windows; on macOS this trades
    // the Finder sidebar for inline options.
    QFileDialog dialog(nullptr, depthMode() ? tr("Export Depth Map")
                                            : tr("Export Result"));
    dialog.setOption(QFileDialog::DontUseNativeDialog);
    dialog.setAcceptMode(QFileDialog::AcceptSave);
    dialog.setFileMode(QFileDialog::AnyFile);
    // The dialog's own filter combo IS the format picker — one control,
    // no redundant "Format:" row; only Color Space needs an accessory.
    // Raw values persist (ExportFormat/ExportColorSpace rawValues); the
    // parallel *Labels lists are display-only. See selectRaw().
    const QStringList formats = {QStringLiteral("TIFF (16-bit)"),
                                 QStringLiteral("DNG (raw)"),
                                 QStringLiteral("PNG (16-bit)"),
                                 QStringLiteral("JPEG")};
    const QStringList formatLabels = {bridgeUIString("tiff16bit"), tr("DNG (raw)"),
                                      tr("PNG (16-bit)"), tr("JPEG")};
    const QStringList suffixes = {QStringLiteral("tif"), QStringLiteral("dng"),
                                  QStringLiteral("png"), QStringLiteral("jpg")};
    QStringList filters;
    for (qsizetype i = 0; i < formats.size(); ++i)
        filters << formatLabels[i] + " (*." + suffixes[i] + ")";
    dialog.setNameFilters(filters);
    dialog.selectNameFilter(filters.value(selectRaw(formats, exportFormat())));
    const QStringList spaces = {QStringLiteral("sRGB"),
                                QStringLiteral("Display P3"),
                                QStringLiteral("ProPhoto RGB")};
    const QStringList spaceLabels = {tr("sRGB"), tr("Display P3"),
                                     tr("ProPhoto RGB")};
    auto *space = new QComboBox(&dialog);
    space->addItems(spaceLabels);
    space->setCurrentIndex(selectRaw(spaces, exportColorSpace()));
    QString savedSpace = exportColorSpace();
    auto applyFormat = [&, space] {
        const qsizetype i =
            qMax(qsizetype(0), filters.indexOf(dialog.selectedNameFilter()));
        dialog.setDefaultSuffix(suffixes.value(i, QStringLiteral("tif")));
        // DNG always carries the full P3 gamut as linear raw: the popup
        // switches to read "Linear Display P3" and disables, restoring
        // the user's choice when another format is picked — the native
        // accessory's behavior.
        const bool dng = formats.value(i) == QStringLiteral("DNG (raw)");
        if (dng && space->isEnabled()) {
            savedSpace = spaces.value(space->currentIndex());
            space->clear();
            space->addItem(bridgeUIString("linearDisplayP3"));
            space->setEnabled(false);
        } else if (!dng && !space->isEnabled()) {
            space->clear();
            space->addItems(spaceLabels);
            space->setCurrentIndex(selectRaw(spaces, savedSpace));
            space->setEnabled(true);
        }
    };
    applyFormat();
    QObject::connect(&dialog, &QFileDialog::filterSelected, &dialog,
                     [&applyFormat](const QString &) { applyFormat(); });
    if (auto *grid = qobject_cast<QGridLayout *>(dialog.layout())) {
        const int row = grid->rowCount();
        grid->addWidget(new QLabel(tr("Color Space:"), &dialog),
                        row, 0, Qt::AlignRight);
        grid->addWidget(space, row, 1);
    }
    if (dialog.exec() != QDialog::Accepted || dialog.selectedFiles().isEmpty())
        return;
    // Both choices persist (the shell's own suite), like the native
    // accessory; the write itself uses them via the model's settings.
    setExportFormat(formats.value(
        qMax(qsizetype(0), filters.indexOf(dialog.selectedNameFilter()))));
    setExportColorSpace(space->isEnabled() ? spaces.value(space->currentIndex())
                                           : savedSpace);
    hf_export(dialog.selectedFiles().first().toUtf8().constData(), nullptr);
}

bool Shell::exportAll(const QUrl &dir) {
    return hf_export_all(dir.toLocalFile().toUtf8().constData()) != 0;
}

bool Shell::exportAligned(const QUrl &dir) {
    return hf_export_aligned(dir.toLocalFile().toUtf8().constData()) != 0;
}

bool Shell::exportAnimation(const QUrl &file) {
    return hf_export_animation(file.toLocalFile().toUtf8().constData()) != 0;
}

bool Shell::saveProject(const QUrl &file) {
    if (file.isEmpty()) return hf_save_project(nullptr) != 0;
    return hf_save_project(file.toLocalFile().toUtf8().constData()) != 0;
}

bool Shell::closeStack() { return hf_close_stack() != 0; }
bool Shell::closeProject() { return hf_close_project() != 0; }

QString Shell::projectPath() const {
    char buffer[1024];
    const int n = hf_project_path(buffer, sizeof buffer);
    return QString::fromUtf8(buffer, n);
}

bool Shell::hasUnsavedWork() const { return hf_has_unsaved_work() != 0; }

void Shell::toneEditing(bool editing) { hf_tone_editing(editing ? 1 : 0); }

void Shell::noiseFloorEditing(bool editing) {
    hf_noise_floor_editing(editing ? 1 : 0);
}

bool Shell::undo() { return hf_undo() != 0; }
bool Shell::redo() { return hf_redo() != 0; }
bool Shell::canUndo() const { return hf_can_undo() != 0; }
bool Shell::canRedo() const { return hf_can_redo() != 0; }

QString Shell::undoTitle() const {
    char buffer[256];
    const int n = hf_undo_title(buffer, sizeof buffer);
    return QString::fromUtf8(buffer, n);
}

QString Shell::redoTitle() const {
    char buffer[256];
    const int n = hf_redo_title(buffer, sizeof buffer);
    return QString::fromUtf8(buffer, n);
}
void Shell::resetTone() { hf_reset_tone(); }
void Shell::resetFusion() { hf_reset_fusion(); }
bool Shell::toneNeutral() const { return hf_tone_is_neutral() != 0; }
bool Shell::fusionDefault() const { return hf_fusion_is_default() != 0; }

void Shell::setAllFramesIncluded(bool included) {
    const int count = hf_frame_count();
    for (int i = 0; i < count; ++i)
        hf_set_frame_included(i, included ? 1 : 0);
}

QVariantList Shell::frames() const { return cachedFrames_; }

QVariantList Shell::buildFrames() const {
    QVariantList list;
    const int count = hf_frame_count();
    list.reserve(count);
    char name[512];
    for (int i = 0; i < count; ++i) {
        int n = hf_frame_name(i, name, sizeof name);
        QVariantMap row;
        row.insert(QStringLiteral("name"), QString::fromUtf8(name, n));
        row.insert(QStringLiteral("included"), hf_frame_included(i) != 0);
        n = hf_frame_issue(i, name, sizeof name);
        row.insert(QStringLiteral("issue"), QString::fromUtf8(name, n));
        list.append(row);
    }
    return list;
}

bool Shell::hasDisplay() const {
    int32_t w = 0, h = 0;
    return hf_display_size(&w, &h) != 0 && w > 0 && h > 0;
}

int Shell::displayEpoch() const { return hf_display_epoch(); }

double Shell::displayTileMean(int cx, int cy) const {
    int32_t w = 0, h = 0;
    if (!hf_display_size(&w, &h) || w <= 0 || h <= 0) return -1;
    const int ts = 16;
    const int x = std::clamp(cx - ts / 2, 0, int(w) - ts);
    const int y = std::clamp(cy - ts / 2, 0, int(h) - ts);
    if (x < 0 || y < 0) return -1;   // display smaller than one tile
    std::vector<uint8_t> rgba(size_t(ts) * ts * 4);
    if (!hf_display_tile(0, x, y, ts, ts, rgba.data(), rgba.size()))
        return -1;
    long long sum = 0;
    for (int i = 0; i < ts * ts; i++)
        sum += rgba[i * 4] + rgba[i * 4 + 1] + rgba[i * 4 + 2];
    return double(sum) / (ts * ts * 3);
}

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

bool Shell::confirmNewProject() { return hf_confirm_new_project() != 0; }

bool Shell::boolSetting(const QString &id) const {
    return hf_bool_setting(id.toUtf8().constData()) == 1;
}

void Shell::setBoolSetting(const QString &id, bool value) {
    hf_set_bool_setting(id.toUtf8().constData(), value ? 1 : 0);
}

double Shell::sidebarWidth() const { return hf_sidebar_width(); }

void Shell::setSidebarWidth(double width) { hf_set_sidebar_width(width); }

QString Shell::uiString(const QString &key) const { return bridgeUIString(key); }

int Shell::infoTipDelayMs() const { return hf_info_tip_delay_ms(); }

bool Shell::gpuAvailable() const { return hf_gpu_available() != 0; }

bool Shell::confirmQuit() {
    QMessageBox box(QMessageBox::Warning,
                    tr("Are you sure you want to quit?"),
                    tr("Unsaved data will be lost."));
    applyAlertIcon(box);
    QAbstractButton *quit = box.addButton(tr("Quit"),
                                          QMessageBox::AcceptRole);
    box.addButton(bridgeUIString("cancel"), QMessageBox::RejectRole);
    box.exec();
    return box.clickedButton() == quit;
}

bool Shell::newProject(const QUrl &folder) {
    return hf_new_project(folder.toLocalFile().toUtf8().constData()) != 0;
}

bool Shell::fuse() { return hf_fuse() != 0; }

bool Shell::exportTo(const QUrl &file) {
    // The chosen extension states the intent; don't inherit whatever
    // format was persisted last (the bridge restores the preference
    // after the write, so this never becomes a sticky settings change).
    const QString path = file.toLocalFile();
    // These are ExportFormat rawValues handed to the bridge, never shown —
    // the displayed labels are built with tr() in exportInteractive().
    const char *format = nullptr;    // unknown extension: persisted format
    if (path.endsWith(QStringLiteral(".tif"), Qt::CaseInsensitive)
        || path.endsWith(QStringLiteral(".tiff"), Qt::CaseInsensitive))
        format = "TIFF (16-bit)";   // i18n-exempt: rawValue
    else if (path.endsWith(QStringLiteral(".dng"), Qt::CaseInsensitive))
        format = "DNG (raw)";       // i18n-exempt: rawValue
    else if (path.endsWith(QStringLiteral(".png"), Qt::CaseInsensitive))
        format = "PNG (16-bit)";    // i18n-exempt: rawValue
    else if (path.endsWith(QStringLiteral(".jpg"), Qt::CaseInsensitive)
             || path.endsWith(QStringLiteral(".jpeg"), Qt::CaseInsensitive))
        format = "JPEG";
    return hf_export(path.toUtf8().constData(), format) != 0;
}
