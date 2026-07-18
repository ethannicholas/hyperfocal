// The output pane: displays the bridge's current image with cursor-anchored
// wheel/pinch zoom and drag pan — the minimal counterpart of the native
// pane's ViewportState behavior. QQuickPaintedItem for the skeleton; the
// production pane becomes a textured QQuickItem with dirty-rect updates
// (plan Phase 2, "same zero-copy discipline the AppKit views use").
#ifndef PANEITEM_H
#define PANEITEM_H

#include <QImage>
#include <QQuickPaintedItem>

class PaneItem : public QQuickPaintedItem {
    Q_OBJECT
    QML_ELEMENT

public:
    explicit PaneItem(QQuickItem *parent = nullptr);

    void paint(QPainter *painter) override;

    // Re-fetch the display image from the bridge (change callback fired).
    Q_INVOKABLE void refresh();

protected:
    void wheelEvent(QWheelEvent *event) override;
    void mousePressEvent(QMouseEvent *event) override;
    void mouseMoveEvent(QMouseEvent *event) override;

private:
    // Fit-relative zoom (1 = fit to pane) and pan offset in image pixels
    // from center — the same coordinate model as the native ViewportState,
    // so the two shells stay comparable.
    double fitScale() const;
    void clampOffset();

    QImage image_;
    double zoom_ = 1.0;
    QPointF offset_;     // image px from center
    QPointF lastPos_;
};

#endif // PANEITEM_H
