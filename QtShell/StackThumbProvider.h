// Serves stack rows' middle-frame thumbnails. QML requests
// "image://hfthumb/<stackIndex>?<token>"; the token (the stacks model's
// thumbToken) keys Shell's main-thread-filled cache — this provider runs on
// QtQuick's pixmap-reader thread, where bridge calls are off-limits (the
// model is main-thread-only; calling in from here trapped in
// MainActor.assumeIsolated). Returns a null image until the background
// generation lands (the delegate stays collapsed while its token is 0).
#ifndef STACKTHUMBPROVIDER_H
#define STACKTHUMBPROVIDER_H

#include <QImage>
#include <QQuickImageProvider>

#include "Shell.h"

class StackThumbProvider : public QQuickImageProvider {
public:
    StackThumbProvider() : QQuickImageProvider(QQuickImageProvider::Image) {}

    QImage requestImage(const QString &id, QSize *size,
                        const QSize &) override {
        const QImage image =
            Shell::thumbnailForToken(id.section(QLatin1Char('?'), 1, 1).toLongLong());
        if (size) *size = image.size();
        return image;
    }
};

#endif // STACKTHUMBPROVIDER_H
