// Serves the tone ramp as a 4096×1 16-bit grayscale texture for the
// pane's LUT shader. QML requests "image://hflut/<epoch>"; the epoch in
// the URL is only a cache-buster — the pixels always come from the
// Shell's current curve.
#ifndef LUTIMAGEPROVIDER_H
#define LUTIMAGEPROVIDER_H

#include <QImage>
#include <QQuickImageProvider>

#include "Shell.h"

class LutImageProvider : public QQuickImageProvider {
public:
    LutImageProvider() : QQuickImageProvider(QQuickImageProvider::Image) {}

    QImage requestImage(const QString &, QSize *size,
                        const QSize &) override {
        const QByteArray lut = Shell::currentLut();
        const int entries = int(lut.size() / 2);
        QImage image(entries > 0 ? entries : 1, 1, QImage::Format_Grayscale16);
        if (entries > 0) {
            memcpy(image.bits(), lut.constData(), size_t(lut.size()));
        } else {
            image.fill(0);
        }
        if (size) *size = image.size();
        return image;
    }
};

#endif // LUTIMAGEPROVIDER_H
