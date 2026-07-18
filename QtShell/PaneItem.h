// The output pane: a tiled, textured scene-graph item showing the bridge's
// current image with cursor-anchored wheel zoom and drag pan — the same
// zero-copy discipline the native AppKit panes use. Pixels arrive as
// hf_display_tile fetches on the GUI thread (the hf_* main-thread
// contract) at a power-of-two level matched to the on-screen scale — full
// resolution once zoom reaches 1:1 — and upload to GPU textures once per
// tile; pan/zoom is a matrix-only scene-graph change, and tone never
// touches tiles (the LUT shader layered over this item applies it). A
// coarse whole-image base texture sits under the sharp tiles so uncovered
// regions show coarse pixels instead of holes while fetches catch up.
#ifndef PANEITEM_H
#define PANEITEM_H

#include <QHash>
#include <QImage>
#include <QQuickItem>

class QSGSimpleTextureNode;

class PaneItem : public QQuickItem {
    Q_OBJECT
    QML_ELEMENT

public:
    explicit PaneItem(QQuickItem *parent = nullptr);

    // Re-check the bridge's display size/epoch (change callback fired);
    // drops every tile iff the pixels actually changed.
    Q_INVOKABLE void refresh();

protected:
    QSGNode *updatePaintNode(QSGNode *node, UpdatePaintNodeData *) override;
    void updatePolish() override;
    void componentComplete() override;
    void geometryChange(const QRectF &newGeometry,
                        const QRectF &oldGeometry) override;
    void wheelEvent(QWheelEvent *event) override;
    void mousePressEvent(QMouseEvent *event) override;
    void mouseMoveEvent(QMouseEvent *event) override;

private:
    struct Tile {
        QImage image;
        QRectF rect;    // covered rect, full-res image coordinates
    };

    // Fit-relative zoom (1 = fit to pane) and pan offset in image pixels
    // from center — the same coordinate model as the native ViewportState,
    // so the two shells stay comparable.
    double fitScale() const;
    void clampOffset();
    int targetLevel() const;
    QRectF visibleImageRect() const;
    void schedule();    // polish (GUI-thread tile fetches) + repaint

    int imgW_ = 0, imgH_ = 0;
    int epoch_ = -1;
    double zoom_ = 1.0;
    QPointF offset_;    // image px from center
    QPointF lastPos_;

    QHash<quint64, Tile> tiles_;    // keyed by (level, tx, ty)
    Tile base_;                     // whole image at a coarse level
    bool reset_ = false;            // epoch changed: rebuild every texture

    // Scene-graph mirrors of base_/tiles_ — owned by the node tree; only
    // touched inside updatePaintNode (GUI thread blocked), and forgotten
    // whenever the tree is rebuilt.
    QHash<quint64, QSGSimpleTextureNode *> nodes_;
    QSGSimpleTextureNode *baseNode_ = nullptr;
};

#endif // PANEITEM_H
