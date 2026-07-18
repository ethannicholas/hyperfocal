// QML-facing facade over the C bridge: commands in, one `changed` signal
// out (the bridge's coalesced change callback). Properties are plain reads
// through the bridge — QML re-reads them on `changed`, mirroring how the
// native views re-render off @Published.
#ifndef SHELL_H
#define SHELL_H

#include <QObject>
#include <QUrl>
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

public:
    explicit Shell(QObject *parent = nullptr);
    ~Shell() override;

    bool canFuse() const;
    bool isRunning() const;
    double stageFraction() const;
    QString stageText() const;
    double exposure() const;
    void setExposure(double ev);

    Q_INVOKABLE bool openStack(const QUrl &folder);
    Q_INVOKABLE bool fuse();
    Q_INVOKABLE bool exportTo(const QUrl &file);

signals:
    void changed();
};

#endif // SHELL_H
