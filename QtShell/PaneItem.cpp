#include "PaneItem.h"

#include <QQuickWindow>
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
    setAcceptedMouseButtons(Qt::LeftButton);
    // Zoomed in, the tiles extend past the pane; the painted item clipped
    // implicitly, the scene graph must be told.
    setClip(true);
}

void PaneItem::componentComplete() {
    QQuickItem::componentComplete();
    refresh();
}

void PaneItem::refresh() {
    int32_t w = 0, h = 0;
    hf_display_size(&w, &h);
    const int epoch = hf_display_epoch();
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
}

double PaneItem::fitScale() const {
    if (imgW_ <= 0 || width() <= 0 || height() <= 0) return 1.0;
    return std::min(width() / imgW_, height() / imgH_);
}

void PaneItem::clampOffset() {
    if (imgW_ <= 0) { offset_ = QPointF(); return; }
    const double hw = imgW_ / 2.0, hh = imgH_ / 2.0;
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
    const double scale = fitScale() * zoom_;
    if (scale <= 0 || imgW_ <= 0) return QRectF();
    const QPointF center(imgW_ / 2.0 + offset_.x(), imgH_ / 2.0 + offset_.y());
    const double w = width() / scale, h = height() / scale;
    return QRectF(center.x() - w / 2, center.y() - h / 2, w, h)
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
        if (hf_display_tile(level, 0, 0, lw, lh, img.bits(),
                            size_t(img.sizeInBytes())))
            base_ = {img, QRectF(0, 0, imgW_, imgH_)};
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
            if (!hf_display_tile(level, x, y, w, h, img.bits(),
                                 size_t(img.sizeInBytes())))
                continue;    // size changed mid-turn; next callback retries
            --budget;
            const double s = double(1 << level);
            tiles_.insert(key, {img,
                QRectF(x * s, y * s,
                       std::min(w * s, imgW_ - x * s),
                       std::min(h * s, imgH_ - y * s))});
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
        return nullptr;
    }
    if (!root) {
        root = new QSGTransformNode;
        nodes_.clear();
        baseNode_ = nullptr;
        reset_ = false;    // building from scratch anyway
    } else if (reset_) {
        while (QSGNode *child = root->firstChild()) delete child;
        nodes_.clear();
        baseNode_ = nullptr;
        reset_ = false;
    }

    // Pan/zoom is only this matrix — no texture touches the bus for it.
    const double scale = fitScale() * zoom_;
    QMatrix4x4 m;
    m.translate(width() / 2, height() / 2);
    m.scale(scale);
    m.translate(-imgW_ / 2.0 - offset_.x(), -imgH_ / 2.0 - offset_.y());
    root->setMatrix(m);

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
        root->prependChildNode(baseNode_);
    }
    if (baseNode_) applyFiltering(baseNode_, base_);

    for (auto it = nodes_.begin(); it != nodes_.end();) {
        if (!tiles_.contains(it.key())) {
            delete it.value();
            it = nodes_.erase(it);
        } else {
            ++it;
        }
    }
    for (auto it = tiles_.cbegin(); it != tiles_.cend(); ++it) {
        auto *&node = nodes_[it.key()];
        if (!node) {
            node = makeNode(it.value());
            root->appendChildNode(node);
        }
        applyFiltering(node, it.value());
    }
    return root;
}

void PaneItem::geometryChange(const QRectF &newGeometry,
                              const QRectF &oldGeometry) {
    QQuickItem::geometryChange(newGeometry, oldGeometry);
    schedule();
}

void PaneItem::wheelEvent(QWheelEvent *event) {
    if (imgW_ <= 0) return;
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
    schedule();
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
    schedule();
}
