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
    Q_PROPERTY(bool canFuse READ canFuse NOTIFY changed)
    Q_PROPERTY(bool isRunning READ isRunning NOTIFY changed)
    Q_PROPERTY(double stageFraction READ stageFraction NOTIFY changed)
    Q_PROPERTY(QString stageText READ stageText NOTIFY changed)
    Q_PROPERTY(double exposure READ exposure WRITE setExposure NOTIFY changed)
    Q_PROPERTY(bool depthMode READ depthMode WRITE setDepthMode NOTIFY changed)
    Q_PROPERTY(QVariantList stacks READ stacks NOTIFY changed)
    Q_PROPERTY(int selectedStack READ selectedStack NOTIFY changed)
    Q_PROPERTY(int pendingStackCount READ pendingStackCount NOTIFY changed)
    Q_PROPERTY(QVariantList frames READ frames NOTIFY changed)
    Q_PROPERTY(bool displayIsData READ displayIsData NOTIFY changed)
    Q_PROPERTY(bool hasInput READ hasInput NOTIFY changed)
    Q_PROPERTY(bool inputLoading READ inputLoading NOTIFY changed)
    Q_PROPERTY(QString inputTitle READ inputTitle NOTIFY changed)
    Q_PROPERTY(int selectedFrame READ selectedFrame NOTIFY changed)
    Q_PROPERTY(QRectF displayCrop READ displayCrop NOTIFY changed)
    Q_PROPERTY(double displayCropAngle READ displayCropAngle NOTIFY changed)
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
    void changed();
};

#endif // SHELL_H
