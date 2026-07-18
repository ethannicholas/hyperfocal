// QML-facing facade over the C bridge: commands in, one `changed` signal
// out (the bridge's coalesced change callback). Properties are plain reads
// through the bridge — QML re-reads them on `changed`, mirroring how the
// native views re-render off @Published.
#ifndef SHELL_H
#define SHELL_H

#include <QByteArray>
#include <QObject>
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
    Q_INVOKABLE bool selectStack(int index);
    Q_INVOKABLE void setStackEnabled(int index, bool enabled);
    Q_INVOKABLE bool fuseEnabledStacks();

signals:
    void changed();
};

#endif // SHELL_H
