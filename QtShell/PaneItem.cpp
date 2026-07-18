#include "PaneItem.h"

#include <QCursor>
#include <QPainter>
#include <QWheelEvent>
#include <algorithm>
#include <vector>

#include "hyperfocal_bridge.h"

PaneItem::PaneItem(QQuickItem *parent) : QQuickPaintedItem(parent) {
    setAcceptedMouseButtons(Qt::LeftButton);
    setFillColor(Qt::black);
    // Panes render at device resolution, not points, or Retina shows 2x soft
    // (the same trap the native panes document).
    setTextureSize(QSize());
}

void PaneItem::refresh() {
    int32_t w = 0, h = 0;
    if (!hf_display_size(&w, &h) || w <= 0 || h <= 0) {
        image_ = QImage();
        update();
        return;
    }
    QImage next(w, h, QImage::Format_RGBA8888);
    if (hf_display_pixels(next.bits(), size_t(next.sizeInBytes()))) {
        image_ = std::move(next);
    }
    update();
}

double PaneItem::fitScale() const {
    if (image_.isNull() || width() <= 0 || height() <= 0) return 1.0;
    return std::min(width() / image_.width(), height() / image_.height());
}

void PaneItem::clampOffset() {
    if (image_.isNull()) { offset_ = QPointF(); return; }
    const double hw = image_.width() / 2.0, hh = image_.height() / 2.0;
    offset_.setX(std::clamp(offset_.x(), -hw, hw));
    offset_.setY(std::clamp(offset_.y(), -hh, hh));
}

void PaneItem::paint(QPainter *painter) {
    if (image_.isNull()) return;
    const double scale = fitScale() * zoom_;
    painter->setRenderHint(QPainter::SmoothPixmapTransform, scale < 2.0);
    painter->translate(width() / 2.0, height() / 2.0);
    painter->scale(scale, scale);
    painter->translate(-image_.width() / 2.0 - offset_.x(),
                       -image_.height() / 2.0 - offset_.y());
    painter->drawImage(0, 0, image_);
}

void PaneItem::wheelEvent(QWheelEvent *event) {
    if (image_.isNull()) return;
    const double steps = event->angleDelta().y() / 120.0;
    if (steps == 0) return;
    const double factor = std::pow(1.15, steps);
    const double before = fitScale() * zoom_;
    zoom_ = std::clamp(zoom_ * factor, 0.2, 64.0);
    const double after = fitScale() * zoom_;
    // Cursor-anchored: keep the image point under the cursor stationary.
    const QPointF pane = event->position() - QPointF(width() / 2, height() / 2);
    offset_ += pane / before - pane / after;
    clampOffset();
    update();
    event->accept();
}

void PaneItem::mousePressEvent(QMouseEvent *event) {
    lastPos_ = event->position();
    event->accept();
}

void PaneItem::mouseMoveEvent(QMouseEvent *event) {
    const QPointF delta = event->position() - lastPos_;
    lastPos_ = event->position();
    offset_ -= delta / (fitScale() * zoom_);
    clampOffset();
    update();
}
