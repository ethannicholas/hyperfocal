#include "PaneItem.h"

#include <QQuickWindow>
#include <QSGClipNode>
#include <QSGSimpleTextureNode>
#include <QSGTransformNode>
#include <QSet>
#include <QTimer>
#include <QWheelEvent>
#include <algorithm>
#include <cmath>

#include "hyperfocal_bridge.h"

namespace {
// Tile edge in level pixels; the base layer caps its longest side at
// BASE_MAX; FETCH_BUDGET bounds tile copies per polish pass so drags stay
// fluid (missing tiles show base pixels and arrive over the next frames);
// CACHE_CAP keeps off-screen tiles around for pan-back before evicting.
constexpr int TILE = 512;
constexpr int BASE_MAX = 1024;
constexpr int FETCH_BUDGET = 8;
constexpr int CACHE_CAP = 96;

quint64 tileKey(int level, int tx, int ty) {
    return (quint64(level) << 48) | (quint64(tx) << 24) | quint64(ty);
}
}  // namespace

PaneItem::PaneItem(QQuickItem *parent) : QQuickItem(parent) {
    setFlag(ItemHasContents);
    // Middle button pans too (the handlers are button-agnostic): in
    // retouch mode left-drag paints, and Windows/Linux get no trackpad
    // pixel-delta pan, so a drag-pan that works in every mode needs a
    // button the overlays never claim.
    setAcceptedMouseButtons(Qt::LeftButton | Qt::MiddleButton);
    // Zoomed in, the tiles extend past the pane; the painted item clipped
    // implicitly, the scene graph must be told.
    setClip(true);
}

void PaneItem::componentComplete() {
    QQuickItem::componentComplete();
    refresh();
}

void PaneItem::setRetouchSource(bool retouch) {
    if (retouch == retouchSource_) return;
    retouchSource_ = retouch;
    epoch_ = -1;    // force a full reset — the epoch counters differ
    refresh();
}

int PaneItem::sourceSize(int32_t *w, int32_t *h) const {
    if (retouchSource_) return hf_retouch_source_size(w, h);
    return input_ ? hf_input_size(w, h) : hf_display_size(w, h);
}

int PaneItem::sourceEpoch() const {
    if (retouchSource_) return hf_retouch_source_epoch();
    return input_ ? hf_input_epoch() : hf_display_epoch();
}

int PaneItem::sourceTile(int level, int x, int y, int w, int h,
                         uint8_t *rgba, size_t cap) const {
    if (retouchSource_)
        return hf_retouch_source_tile(level, x, y, w, h, rgba, cap);
    return input_ ? hf_input_tile(level, x, y, w, h, rgba, cap)
                  : hf_display_tile(level, x, y, w, h, rgba, cap);
}

int PaneItem::sourceCrop(double *x, double *y, double *w, double *h,
                         double *angle) const {
    return input_ ? hf_input_crop(x, y, w, h, angle)
                  : hf_display_crop(x, y, w, h, angle);
}

int PaneItem::sourceNominal(int32_t *w, int32_t *h) const {
    if (retouchSource_) return hf_retouch_source_nominal(w, h);
    return input_ ? hf_input_nominal(w, h) : hf_display_nominal(w, h);
}

QRectF PaneItem::viewportRect() const {
    return crop_.isEmpty() ? QRectF(0, 0, nomW_, nomH_) : crop_;
}

QMatrix4x4 PaneItem::viewportMatrix() const {
    // Fit/zoom/pan maps the viewport (crop or whole image) to the pane;
    // the crop rect stays axis-aligned under this part.
    const QPointF center = viewportRect().center();
    QMatrix4x4 m;
    m.translate(width() / 2, height() / 2);
    m.scale(fitScale() * zoom_);
    m.translate(-center.x() - offset_.x(), -center.y() - offset_.y());
    return m;
}

QMatrix4x4 PaneItem::rotationMatrix() const {
    // An angled crop rotates the image content by -angle about the
    // rect's center — the native presentation, and what export samples.
    QMatrix4x4 m;
    if (cropAngle_ != 0 && !crop_.isEmpty()) {
        const QPointF center = crop_.center();
        m.translate(center.x(), center.y());
        m.rotate(-cropAngle_, 0, 0, 1);
        m.translate(-center.x(), -center.y());
    }
    return m;
}

QMatrix4x4 PaneItem::imageToNominal() const {
    // Tiles live in image pixels; this lifts them into nominal canvas
    // space (identity except mid-fuse).
    QMatrix4x4 m;
    if (imgW_ > 0 && imgH_ > 0 && (nomW_ != imgW_ || nomH_ != imgH_))
        m.scale(double(nomW_) / imgW_, double(nomH_) / imgH_);
    return m;
}

QMatrix4x4 PaneItem::contentMatrix() const {
    return viewportMatrix() * rotationMatrix() * imageToNominal();
}

void PaneItem::pushViewport() {
    if (sync_) sync_->adoptViewport(zoom_, offset_);
}

void PaneItem::adoptViewport(double zoom, QPointF offset) {
    if (zoom == zoom_ && offset == offset_) return;
    zoom_ = zoom;
    offset_ = offset;
    clampOffset();
    schedule();
}

QPointF PaneItem::mapToCanvas(QPointF pane) const {
    bool invertible = false;
    const QMatrix4x4 inverse = viewportMatrix().inverted(&invertible);
    return invertible ? inverse.map(pane) : pane;
}

QPointF PaneItem::mapFromCanvas(QPointF image) const {
    return viewportMatrix().map(image);
}

QPointF PaneItem::mapToImage(QPointF pane) const {
    bool invertible = false;
    const QMatrix4x4 inverse = contentMatrix().inverted(&invertible);
    return invertible ? inverse.map(pane) : pane;
}

QPointF PaneItem::mapFromImage(QPointF image) const {
    return contentMatrix().map(image);
}

void PaneItem::refresh() {
    int32_t w = 0, h = 0;
    sourceSize(&w, &h);
    int32_t nw = 0, nh = 0;
    sourceNominal(&nw, &nh);
    if (nw <= 0) { nw = w; nh = h; }
    if (nw != nomW_ || nh != nomH_) {
        nomW_ = nw;
        nomH_ = nh;
        clampOffset();
        schedule();
    }
    const int epoch = sourceEpoch();
    // Retouch strokes: epoch moved but the size didn't, and the bridge
    // has a dirty rect — evict only intersecting tiles instead of
    // resetting the whole cache (the 45 MP full-rebuild trap the native
    // canvas also avoids). The coarse base is refetched on a debounce
    // so zoomed-out views converge without per-stroke 1024px copies.
    if (!input_ && !retouchSource_ && epoch != epoch_
        && w == imgW_ && h == imgH_ && imgW_ > 0) {
        int32_t dx = 0, dy = 0, dw = 0, dh = 0;
        if (hf_display_dirty(&dx, &dy, &dw, &dh)) {
            epoch_ = epoch;
            const QRectF dirty(dx, dy, dw, dh);
            for (auto it = tiles_.begin(); it != tiles_.end();) {
                if (it.value().rect.intersects(dirty)) it = tiles_.erase(it);
                else ++it;
            }
            if (++dirtSinceBase_ >= 12) {
                dirtSinceBase_ = 0;
                base_ = Tile();
            }
            schedule();
            return;
        }
    }
    double cx = 0, cy = 0, cw = 0, ch = 0, cangle = 0;
    sourceCrop(&cx, &cy, &cw, &ch, &cangle);
    const QRectF crop(cx, cy, cw, ch);
    // A crop change is viewport-only: pixels (and the fetched tiles)
    // stay valid; the node tree rebuilds from the cached images so the
    // clip takes hold.
    if (crop != crop_ || cangle != cropAngle_) {
        crop_ = crop;
        cropAngle_ = cangle;
        reset_ = true;
        clampOffset();
        schedule();
    }
    if (epoch == epoch_ && w == imgW_ && h == imgH_) return;
    epoch_ = epoch;
    imgW_ = w;
    imgH_ = h;
    tiles_.clear();
    base_ = Tile();
    reset_ = true;
    schedule();
}

void PaneItem::schedule() {
    polish();
    update();
    emit viewportChanged();
}

void PaneItem::zoomBy(double factor) { setZoom(zoom_ * factor); }

void PaneItem::setAbsoluteScale(double scale) {
    const double fitTo = fitScale();
    if (fitTo > 0) setZoom(scale / fitTo);
}

void PaneItem::fit() {
    offset_ = QPointF();
    setZoom(1);
}

void PaneItem::setZoom(double zoom) {
    zoom_ = std::clamp(zoom, 0.2, 64.0);
    clampOffset();
    pushViewport();
    schedule();
}

double PaneItem::fitScale() const {
    if (imgW_ <= 0 || width() <= 0 || height() <= 0) return 1.0;
    const QRectF viewport = viewportRect();
    return std::min(width() / viewport.width(), height() / viewport.height());
}

void PaneItem::clampOffset() {
    // No image (e.g. the gap between Fuse and the first progressive) is
    // not a reason to recenter — the pan must survive so the viewport
    // holds steady when pixels return.
    if (imgW_ <= 0) return;
    const QRectF viewport = viewportRect();
    const double hw = viewport.width() / 2.0, hh = viewport.height() / 2.0;
    offset_.setX(std::clamp(offset_.x(), -hw, hw));
    offset_.setY(std::clamp(offset_.y(), -hh, hh));
}

int PaneItem::targetLevel() const {
    // The level whose texels land at 0.5–1 device pixel on screen — full
    // resolution once the on-screen scale reaches 1:1.
    const double dpr = window() ? window()->effectiveDevicePixelRatio() : 1.0;
    double scale = fitScale() * zoom_ * dpr;
    int level = 0;
    while (scale < 0.5 && (std::max(imgW_, imgH_) >> (level + 1)) >= 1) {
        scale *= 2;
        ++level;
    }
    return level;
}

QRectF PaneItem::visibleImageRect() const {
    if (fitScale() * zoom_ <= 0 || imgW_ <= 0) return QRectF();
    // Inverse-map the pane onto the image; with an angled crop the
    // bounding rect over-covers a little, which only means a few spare
    // tile fetches under the clipped corners.
    bool invertible = false;
    const QMatrix4x4 inverse = contentMatrix().inverted(&invertible);
    if (!invertible) return QRectF();
    return inverse.mapRect(QRectF(0, 0, width(), height()))
        .intersected(QRectF(0, 0, imgW_, imgH_));
}

void PaneItem::updatePolish() {
    // GUI thread — the only place bridge pixels are fetched (hf_* contract).
    if (imgW_ <= 0) return;

    if (base_.image.isNull()) {
        int level = 0;
        while ((std::max(imgW_, imgH_) >> level) > BASE_MAX) ++level;
        const int lw = (imgW_ + (1 << level) - 1) >> level;
        const int lh = (imgH_ + (1 << level) - 1) >> level;
        QImage img(lw, lh, QImage::Format_RGBA8888);
        if (sourceTile(level, 0, 0, lw, lh, img.bits(),
                       size_t(img.sizeInBytes()))) {
            base_ = {img, QRectF(0, 0, imgW_, imgH_)};
            basePending_ = true;
        }
    }

    const int level = targetLevel();
    const int lw = (imgW_ + (1 << level) - 1) >> level;
    const int lh = (imgH_ + (1 << level) - 1) >> level;
    const QRectF vis = visibleImageRect();
    if (vis.isEmpty()) return;
    const int lx0 = std::max(0, int(std::floor(vis.left())) >> level);
    const int ly0 = std::max(0, int(std::floor(vis.top())) >> level);
    const int lx1 = std::min(lw - 1, int(std::ceil(vis.right())) >> level);
    const int ly1 = std::min(lh - 1, int(std::ceil(vis.bottom())) >> level);

    QSet<quint64> wanted;
    int budget = FETCH_BUDGET;
    bool starved = false;
    for (int ty = ly0 / TILE; ty <= ly1 / TILE; ++ty) {
        for (int tx = lx0 / TILE; tx <= lx1 / TILE; ++tx) {
            const quint64 key = tileKey(level, tx, ty);
            wanted.insert(key);
            if (tiles_.contains(key)) continue;
            if (budget <= 0) { starved = true; continue; }
            const int x = tx * TILE, y = ty * TILE;
            const int w = std::min(TILE, lw - x), h = std::min(TILE, lh - y);
            QImage img(w, h, QImage::Format_RGBA8888);
            if (!sourceTile(level, x, y, w, h, img.bits(),
                            size_t(img.sizeInBytes())))
                continue;    // size changed mid-turn; next callback retries
            --budget;
            const double s = double(1 << level);
            tiles_.insert(key, {img,
                QRectF(x * s, y * s,
                       std::min(w * s, imgW_ - x * s),
                       std::min(h * s, imgH_ - y * s))});
            pendingUpload_.insert(key);
        }
    }
    if (tiles_.size() > CACHE_CAP) {
        for (auto it = tiles_.begin();
             it != tiles_.end() && tiles_.size() > CACHE_CAP;) {
            if (!wanted.contains(it.key())) it = tiles_.erase(it);
            else ++it;
        }
    }
    // More visible tiles than one pass's budget: keep fetching next frame.
    if (starved) QTimer::singleShot(0, this, [this] { schedule(); });
    update();
}

QSGNode *PaneItem::updatePaintNode(QSGNode *oldNode, UpdatePaintNodeData *) {
    auto *root = static_cast<QSGTransformNode *>(oldNode);
    if (imgW_ <= 0 || (base_.image.isNull() && tiles_.isEmpty())) {
        delete root;
        nodes_.clear();
        baseNode_ = nullptr;
        clipNode_ = nullptr;
        contentNode_ = nullptr;
        levelGroups_.clear();
        return nullptr;
    }
    if (!root) {
        root = new QSGTransformNode;
        nodes_.clear();
        baseNode_ = nullptr;
        clipNode_ = nullptr;
        contentNode_ = nullptr;
        levelGroups_.clear();
        reset_ = false;    // building from scratch anyway
    } else if (reset_) {
        while (QSGNode *child = root->firstChild()) delete child;
        nodes_.clear();
        baseNode_ = nullptr;
        clipNode_ = nullptr;
        contentNode_ = nullptr;
        levelGroups_.clear();
        reset_ = false;
    }

    // Pan/zoom is only these matrices — no texture touches the bus for
    // it. The clip sits between them: bounded to the (axis-aligned under
    // viewportMatrix) crop rect, while the content below it tilts.
    const double scale = fitScale() * zoom_;
    root->setMatrix(viewportMatrix());

    // The clip's geometry is mandatory — isRectangular/clipRect is only
    // the scissor fast path, and once ancestors rotate (or a layer grab
    // re-bases the transform) the renderer falls back to stencil
    // clipping, which renders the geometry (a null one crashes the batch
    // renderer).
    if (!clipNode_) {
        clipNode_ = new QSGClipNode;
        clipNode_->setFlag(QSGNode::OwnsGeometry);
        auto *geometry =
            new QSGGeometry(QSGGeometry::defaultAttributes_Point2D(), 4);
        QSGGeometry::updateRectGeometry(geometry, viewportRect());
        clipNode_->setGeometry(geometry);
        clipNode_->setIsRectangular(true);
        clipNode_->setClipRect(viewportRect());
        root->appendChildNode(clipNode_);
        contentNode_ = new QSGTransformNode;
        clipNode_->appendChildNode(contentNode_);
    }
    contentNode_->setMatrix(rotationMatrix() * imageToNominal());

    auto *win = window();
    auto makeNode = [&](const Tile &tile) {
        auto *node = new QSGSimpleTextureNode;
        node->setOwnsTexture(true);
        node->setTexture(win->createTextureFromImage(tile.image));
        node->setRect(tile.rect);
        return node;
    };
    // Smooth until texels reach 2x on screen, then nearest so deep zoom
    // shows actual pixels — the painted pane's interpolation rule.
    auto applyFiltering = [&](QSGSimpleTextureNode *node, const Tile &tile) {
        const double texel = scale * tile.rect.width() / tile.image.width();
        node->setFiltering(texel < 2.0 ? QSGTexture::Linear
                                       : QSGTexture::Nearest);
    };

    if (!baseNode_ && !base_.image.isNull()) {
        baseNode_ = makeNode(base_);
        // First child renders first: the coarse base stays under the tiles.
        contentNode_->prependChildNode(baseNode_);
    } else if (baseNode_ && basePending_ && !base_.image.isNull()) {
        // Refetched base (stroke dirt debounce): swap the texture in
        // place — setTexture deletes the old one under ownsTexture.
        baseNode_->setTexture(win->createTextureFromImage(base_.image));
    }
    basePending_ = false;
    if (baseNode_) applyFiltering(baseNode_, base_);

    for (auto it = nodes_.begin(); it != nodes_.end();) {
        if (!tiles_.contains(it.key())) {
            delete it.value();
            it = nodes_.erase(it);
        } else {
            ++it;
        }
    }
    // Tiles hang in per-level groups sorted coarse→fine: a cached
    // other-level tile rendered later must never cover the current
    // level's pixels (the zoom-out-then-in trap).
    auto groupFor = [&](int level) -> QSGNode * {
        auto *&group = levelGroups_[level];
        if (group) return group;
        group = new QSGNode;
        QSGNode *nextFiner = nullptr;
        int nextFinerLevel = -1;
        for (auto it = levelGroups_.cbegin(); it != levelGroups_.cend(); ++it) {
            if (it.key() < level && it.key() > nextFinerLevel) {
                nextFiner = it.value();
                nextFinerLevel = it.key();
            }
        }
        if (nextFiner) contentNode_->insertChildNodeBefore(group, nextFiner);
        else contentNode_->appendChildNode(group);
        return group;
    };
    for (auto it = tiles_.cbegin(); it != tiles_.cend(); ++it) {
        auto *&node = nodes_[it.key()];
        if (!node) {
            node = makeNode(it.value());
            groupFor(int(it.key() >> 48))->appendChildNode(node);
        } else if (pendingUpload_.contains(it.key())) {
            // Same key, fresh pixels (a stroke's dirty-rect refetch):
            // the node survives eviction+refetch between paints, so its
            // texture must be replaced explicitly.
            node->setTexture(win->createTextureFromImage(it.value().image));
        }
        applyFiltering(node, it.value());
    }
    pendingUpload_.clear();
    return root;
}

void PaneItem::geometryChange(const QRectF &newGeometry,
                              const QRectF &oldGeometry) {
    QQuickItem::geometryChange(newGeometry, oldGeometry);
    schedule();
}

void PaneItem::zoomAnchored(double factor, QPointF pos) {
    const double before = fitScale() * zoom_;
    zoom_ = std::clamp(zoom_ * factor, 0.2, 64.0);
    const double after = fitScale() * zoom_;
    // Anchored: keep the image point under the cursor stationary.
    const QPointF pane = pos - QPointF(width() / 2, height() / 2);
    offset_ += pane / before - pane / after;
    clampOffset();
    pushViewport();
    schedule();
}

void PaneItem::wheelEvent(QWheelEvent *event) {
    if (imgW_ <= 0) return;
    event->accept();
    // Trackpad two-finger scrolls carry pixel deltas and PAN, matching
    // the native gesture; discrete mouse wheels (angle deltas only)
    // keep zooming.
    if (!event->pixelDelta().isNull()) {
        const double scale = fitScale() * zoom_;
        if (scale <= 0) return;
        offset_ -= QPointF(event->pixelDelta()) / scale;
        clampOffset();
        pushViewport();
        schedule();
        return;
    }
    const double steps = event->angleDelta().y() / 120.0;
    if (steps == 0) return;
    zoomAnchored(std::pow(1.15, steps), event->position());
}

bool PaneItem::event(QEvent *event) {
    // Pinch zooms (anchored under the fingers); smart zoom (two-finger
    // double tap) toggles fit ↔ 1:1, both as on the native panes.
    if (event->type() == QEvent::NativeGesture && imgW_ > 0) {
        auto *gesture = static_cast<QNativeGestureEvent *>(event);
        if (gesture->gestureType() == Qt::ZoomNativeGesture) {
            zoomAnchored(1.0 + gesture->value(), gesture->position());
            return true;
        }
        if (gesture->gestureType() == Qt::SmartZoomNativeGesture) {
            if (fitted()) setAbsoluteScale(1);
            else fit();
            return true;
        }
    }
    return QQuickItem::event(event);
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
    pushViewport();
    schedule();
}
