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
#include <QMatrix4x4>
#include <QQuickItem>

class QSGClipNode;
class QSGSimpleTextureNode;
class QSGTransformNode;

class PaneItem : public QQuickItem {
    Q_OBJECT
    QML_ELEMENT
    // Which bridge surface this pane shows: the output display (default)
    // or the input pane (hf_input_*). Set once at creation.
    Q_PROPERTY(bool input READ isInput WRITE setInput)
    // Reroutes an input pane to the retouch source surface while the
    // mode is active (hf_retouch_source_*).
    Q_PROPERTY(bool retouchSource READ isRetouchSource WRITE setRetouchSource)
    // Buddy pane sharing this pane's viewport (the native shells share
    // one ViewportState across input/output): pan/zoom here is pushed
    // there, one-way per gesture, so comparing panes stays aligned.
    Q_PROPERTY(PaneItem *syncPane READ syncPane WRITE setSyncPane)
    // On-screen scale in image pixels per pane point (1 = 1:1) — the
    // zoom bar's currency, following every viewport change.
    Q_PROPERTY(double displayScale READ displayScale NOTIFY viewportChanged)
    // Fit is a MODE (zoom 1, centered — it re-fits on resize); the zoom
    // bar reads "Fit" while it holds, a percentage once zoomed/panned.
    Q_PROPERTY(bool fitted READ fitted NOTIFY viewportChanged)

public:
    explicit PaneItem(QQuickItem *parent = nullptr);

    bool isInput() const { return input_; }
    void setInput(bool input) { input_ = input; }
    bool isRetouchSource() const { return retouchSource_; }
    void setRetouchSource(bool retouch);
    PaneItem *syncPane() const { return sync_; }
    void setSyncPane(PaneItem *pane) { sync_ = pane; }

    // Re-check the bridge's display size/epoch (change callback fired);
    // drops every tile iff the pixels actually changed.
    Q_INVOKABLE void refresh();

    // Screen↔canvas mapping for overlays (the crop overlay's drag math
    // runs in canvas pixels): the pan/zoom part only — overlays draw
    // their own rotation.
    Q_INVOKABLE QPointF mapToCanvas(QPointF pane) const;
    Q_INVOKABLE QPointF mapFromCanvas(QPointF image) const;
    // Full transform incl. crop rotation — stroke coordinates.
    Q_INVOKABLE QPointF mapToImage(QPointF pane) const;
    Q_INVOKABLE QPointF mapFromImage(QPointF image) const;

    // Center-anchored programmatic zoom (fit-relative, clamped like the
    // wheel) — the selftest's zoom-cycle journey drives this.
    Q_INVOKABLE void setZoom(double zoom);
    // The zoom bar's verbs: multiply the current zoom, jump to an
    // absolute image scale (1 = 1:1), or refit (zoom 1, centered).
    Q_INVOKABLE void zoomBy(double factor);
    Q_INVOKABLE void setAbsoluteScale(double scale);
    Q_INVOKABLE void fit();
    double displayScale() const { return fitScale() * zoom_; }
    bool fitted() const { return zoom_ == 1.0 && offset_.isNull(); }

signals:
    void viewportChanged();

protected:
    bool event(QEvent *event) override;
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

    // The bridge surface behind this pane (hf_display_* or hf_input_*).
    int sourceSize(int32_t *w, int32_t *h) const;
    int sourceEpoch() const;
    int sourceTile(int level, int x, int y, int w, int h,
                   uint8_t *rgba, size_t cap) const;
    int sourceCrop(double *x, double *y, double *w, double *h,
                   double *angle) const;
    int sourceNominal(int32_t *w, int32_t *h) const;

    // The presented viewport: the crop rect when one is active, else the
    // whole image. The image→item transform factors as viewportMatrix
    // (fit/zoom/pan — the crop rect stays axis-aligned under it) times
    // rotationMatrix (image content rotated by -angle about the crop
    // center); the clip lives between the two so the crop's edges stay
    // straight while the content tilts, the native presentation.
    QRectF viewportRect() const;
    QMatrix4x4 viewportMatrix() const;
    QMatrix4x4 rotationMatrix() const;
    QMatrix4x4 imageToNominal() const;   // tiles (image px) → nominal
    QMatrix4x4 contentMatrix() const;    // viewport * rotation * toNominal

    // Cursor-anchored zoom shared by wheel and pinch.
    void zoomAnchored(double factor, QPointF pos);

    // Mirror this pane's viewport onto the buddy after a gesture here.
    void pushViewport();
    void adoptViewport(double zoom, QPointF offset);

    bool input_ = false;
    bool retouchSource_ = false;
    PaneItem *sync_ = nullptr;
    // Debounce for coarse-base refetches while stroke dirt streams in.
    int dirtSinceBase_ = 0;

    int imgW_ = 0, imgH_ = 0;
    // Nominal canvas the viewport lives in (== image size except
    // mid-fuse, when progressives render smaller): tiles scale into
    // nominal space so pan/zoom holds steady across a fuse.
    int nomW_ = 0, nomH_ = 0;
    int epoch_ = -1;
    QRectF crop_;       // active crop in image px; empty = full image
    double cropAngle_ = 0;
    double zoom_ = 1.0;
    QPointF offset_;    // image px from viewport center
    QPointF lastPos_;

    QHash<quint64, Tile> tiles_;    // keyed by (level, tx, ty)
    // Tiles whose pixels changed since the last paint (dirty-rect
    // refetches): their existing nodes need a texture REPLACEMENT —
    // node presence alone must not imply texture currency.
    QSet<quint64> pendingUpload_;
    Tile base_;                     // whole image at a coarse level
    bool basePending_ = false;
    bool reset_ = false;            // epoch changed: rebuild every texture

    // Scene-graph mirrors of base_/tiles_ — owned by the node tree; only
    // touched inside updatePaintNode (GUI thread blocked), and forgotten
    // whenever the tree is rebuilt. Textures hang under a clip node that
    // bounds them to the presented viewport (the crop rect).
    QHash<quint64, QSGSimpleTextureNode *> nodes_;
    QSGSimpleTextureNode *baseNode_ = nullptr;
    QSGClipNode *clipNode_ = nullptr;
    QSGTransformNode *contentNode_ = nullptr;
    // One child group per level, kept sorted coarse→fine under
    // contentNode_ so finer tiles always paint over coarser ones —
    // cached other-level tiles must never cover the current level.
    QHash<int, QSGNode *> levelGroups_;
};

#endif // PANEITEM_H
