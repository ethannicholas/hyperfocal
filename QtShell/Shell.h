// QML-facing facade over the C bridge: commands in, one `changed` signal
// out (the bridge's coalesced change callback). Properties are plain reads
// through the bridge — QML re-reads them on `changed`, mirroring how the
// native views re-render off @Published.
#ifndef SHELL_H
#define SHELL_H

#include <QByteArray>
#include <QObject>
#include <QRectF>
#include <QUrl>
#include <QVariantList>
#include <qqmlregistration.h>

class Shell : public QObject {
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    // Signal granularity is load-bearing for responsiveness: fusion
    // progress ticks many times a second, and a single coarse changed()
    // made every tick re-evaluate every binding — including the frames/
    // stacks lists, whose delegates rebuilt wholesale each time. The
    // lists are cached and diffed (framesChanged/stacksChanged fire only
    // on real change), progress scalars ride progressChanged, and
    // changed() fires only when the remaining fingerprint moves.
    Q_PROPERTY(bool canFuse READ canFuse NOTIFY stacksChanged)
    Q_PROPERTY(bool isRunning READ isRunning NOTIFY progressChanged)
    Q_PROPERTY(double stageFraction READ stageFraction NOTIFY progressChanged)
    Q_PROPERTY(QString stageText READ stageText NOTIFY progressChanged)
    Q_PROPERTY(double exposure READ exposure WRITE setExposure NOTIFY changed)
    Q_PROPERTY(bool depthMode READ depthMode WRITE setDepthMode NOTIFY changed)
    Q_PROPERTY(QVariantList stacks READ stacks NOTIFY stacksChanged)
    Q_PROPERTY(int selectedStack READ selectedStack NOTIFY stacksChanged)
    Q_PROPERTY(int pendingStackCount READ pendingStackCount NOTIFY stacksChanged)
    Q_PROPERTY(QVariantList frames READ frames NOTIFY framesChanged)
    Q_PROPERTY(bool displayIsData READ displayIsData NOTIFY changed)
    Q_PROPERTY(bool hasInput READ hasInput NOTIFY changed)
    Q_PROPERTY(bool inputLoading READ inputLoading NOTIFY changed)
    Q_PROPERTY(QString inputTitle READ inputTitle NOTIFY changed)
    Q_PROPERTY(int selectedFrame READ selectedFrame NOTIFY framesChanged)
    Q_PROPERTY(QRectF displayCrop READ displayCrop NOTIFY changed)
    Q_PROPERTY(double displayCropAngle READ displayCropAngle NOTIFY changed)
    Q_PROPERTY(int fusedStackCount READ fusedStackCount NOTIFY stacksChanged)
    Q_PROPERTY(bool canExportAligned READ canExportAligned NOTIFY stacksChanged)
    Q_PROPERTY(bool canAnimate READ canAnimate NOTIFY stacksChanged)
    Q_PROPERTY(QString exportFormat READ exportFormat WRITE setExportFormat NOTIFY changed)
    Q_PROPERTY(QString exportColorSpace READ exportColorSpace WRITE setExportColorSpace NOTIFY changed)
    Q_PROPERTY(QString animationStrength READ animationStrength WRITE setAnimationStrength NOTIFY changed)
    Q_PROPERTY(bool toneNeutral READ toneNeutral NOTIFY changed)
    Q_PROPERTY(bool fusionDefault READ fusionDefault NOTIFY changed)
    Q_PROPERTY(bool hasDisplay READ hasDisplay NOTIFY changed)
    Q_PROPERTY(QString projectPath READ projectPath NOTIFY changed)
    Q_PROPERTY(bool hasUnsavedWork READ hasUnsavedWork NOTIFY changed)
    Q_PROPERTY(bool canUndo READ canUndo NOTIFY changed)
    Q_PROPERTY(bool canRedo READ canRedo NOTIFY changed)
    Q_PROPERTY(QString undoTitle READ undoTitle NOTIFY changed)
    Q_PROPERTY(QString redoTitle READ redoTitle NOTIFY changed)
    Q_PROPERTY(int lutEpoch READ lutEpoch NOTIFY changed)

public:
    explicit Shell(QObject *parent = nullptr);
    ~Shell() override;

    bool canFuse() const;
    bool isRunning() const;
    double stageFraction() const;
    QString stageText() const;
    double exposure() const;
    void setExposure(double ev);

    bool depthMode() const;
    void setDepthMode(bool depth);
    QVariantList stacks() const;
    int selectedStack() const;
    int pendingStackCount() const;
    QVariantList frames() const;
    bool displayIsData() const;
    bool hasInput() const;
    // The selected frame's decode is in flight — the input pane still
    // shows the previous image (the title already names the new frame).
    bool inputLoading() const;
    QString inputTitle() const;
    int selectedFrame() const;
    /// Bumps only when the tone curve's bytes actually change — the LUT
    /// Image reloads off this, not off every model change.
    int lutEpoch() const;

    Q_INVOKABLE bool openStack(const QUrl &folder);
    Q_INVOKABLE bool fuse();
    Q_INVOKABLE bool exportTo(const QUrl &file);
    /// The current 16-bit tone ramp (4096 entries) for the LUT provider.
    static QByteArray currentLut();

    Q_INVOKABLE bool hasDisplay() const;
    /// Display-pixel currency, exposed for the selftest: the epoch moves
    /// exactly when the display image's pixels change (never for tone),
    /// and the size is the full result resolution.
    Q_INVOKABLE int displayEpoch() const;
    Q_INVOKABLE int displayWidth() const;
    Q_INVOKABLE int displayHeight() const;
    Q_INVOKABLE double slider(const QString &id) const;
    Q_INVOKABLE void setSlider(const QString &id, double value);
    Q_INVOKABLE void setFrameIncluded(int index, bool included);
    Q_INVOKABLE void selectFrame(int index);
    /// Crop, result-canvas px + degrees (the UITest set-crop semantics:
    /// w/h <= 0 clears). displayCrop is empty when none presents.
    Q_INVOKABLE void setCrop(double x, double y, double w, double h,
                             double angle);
    QRectF displayCrop() const;
    double displayCropAngle() const;
    Q_INVOKABLE bool selectStack(int index);
    Q_INVOKABLE void setStackEnabled(int index, bool enabled);
    Q_INVOKABLE bool fuseEnabledStacks();
    Q_INVOKABLE bool cancelFuse();
    Q_INVOKABLE void resetTone();
    Q_INVOKABLE void resetFusion();
    /// Set every frame's checkbox at once (Include All / None).
    Q_INVOKABLE void setAllFramesIncluded(bool included);
    bool toneNeutral() const;
    bool fusionDefault() const;
    int fusedStackCount() const;
    bool canExportAligned() const;
    bool canAnimate() const;
    QString exportFormat() const;
    void setExportFormat(const QString &name);
    QString exportColorSpace() const;
    void setExportColorSpace(const QString &name);
    QString animationStrength() const;
    void setAnimationStrength(const QString &name);
    Q_INVOKABLE bool exportAll(const QUrl &dir);
    Q_INVOKABLE bool exportAligned(const QUrl &dir);
    Q_INVOKABLE bool exportAnimation(const QUrl &file);
    /// Save to `file`, or to the existing project file when empty
    /// (returns false when there is none yet — caller then asks).
    Q_INVOKABLE bool saveProject(const QUrl &file);
    Q_INVOKABLE bool closeStack();
    Q_INVOKABLE bool closeProject();
    QString projectPath() const;
    bool hasUnsavedWork() const;
    Q_INVOKABLE void toneEditing(bool editing);
    Q_INVOKABLE bool undo();
    Q_INVOKABLE bool redo();
    bool canUndo() const;
    bool canRedo() const;
    QString undoTitle() const;
    QString redoTitle() const;

signals:
    /// Every bridge callback (panes listen and self-guard by epoch).
    void tick();
    /// Fusion progress scalars moved (fraction/text/isRunning).
    void progressChanged();
    /// The frame list (or frame selection) actually changed.
    void framesChanged();
    /// The stack list (selection, statuses, pending count) actually changed.
    void stacksChanged();
    /// Anything else (tone, crop, project, undo state, …) moved.
    void changed();

public:
    /// One pass per bridge callback (queued to the next turn): rebuild
    /// the cached lists, diff, and emit only the granular signals whose
    /// data moved.
    void refreshFromBridge();

private:
    QVariantList buildStacks() const;
    QVariantList buildFrames() const;
    QVariantList fingerprint() const;

    QVariantList cachedStacks_, cachedFrames_, cachedFingerprint_;
    double cachedFraction_ = -1;
    QString cachedStage_;
    bool cachedRunning_ = false;
    int cachedSelectedStack_ = -1, cachedSelectedFrame_ = -1;
    int cachedPending_ = 0;
    bool cachedCanFuse_ = false;
};

#endif // SHELL_H
