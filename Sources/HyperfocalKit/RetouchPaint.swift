import Foundation
import Dispatch

/// The retouch brush's per-pixel loops. They live in the Kit — not in the
/// model layer that owns the session state — for the same reason the fusion
/// loops do: Package.swift keeps the Kit at `-O` in every configuration,
/// while the model layer builds -Onone in Debug, and these loops at -Onone
/// run ~30x slower (measured 3 ms per r=25 stamp, 27 ms at r=150, on a
/// 45 MP canvas). At those costs a drag's stamps outrun the event loop:
/// mouse events coalesce, sample points spread out, and strokes render as
/// straight polygon segments — a Debug build running them -Onone is
/// unpaintable on large stacks.
///
/// All functions take base pointers into full `width`-stride interleaved
/// planes (RGBA f16 pixels, RGBA8 display bytes, scalar Float depth,
/// gray8 depth display) and are pure pixel arithmetic: ownership, tiling,
/// undo, and invalidation stay with the caller. The display-byte and
/// depth-display formulas here are the single source of those planes'
/// quantization — the session's full-plane conversions and the per-stamp
/// incremental updates must round identically or repainted regions shimmer
/// against untouched ones.
public enum RetouchPaint {

    /// Wrapper for pointer captures in concurrentPerform's @Sendable
    /// closure. Safety is structural: each iteration writes disjoint rows,
    /// and the pointers outlive the (synchronous) call.
    private struct UncheckedSendable<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }

    /// One brush stamp: blend `source` over `working` inside the circle at
    /// (`centerX`, `centerY`) — hard core out to `inner`, smoothstep falloff
    /// to `radius` — mirroring every written pixel into the display plane,
    /// and co-painting the depth plane when `paintsDepth` (toward
    /// `originalDepth` for the eraser, `frameDepth` otherwise).
    /// `x0…y1` is the circle's bounding box, already clamped to the canvas.
    /// Source alpha 0 is "no data here" (warp out-of-bounds) and never
    /// paints.
    public static func stamp(
        working: UnsafeMutablePointer<Float16>,
        source: UnsafePointer<Float16>,
        display: UnsafeMutablePointer<UInt8>,
        workingDepth: UnsafeMutablePointer<Float>,
        originalDepth: UnsafePointer<Float>,
        depthDisplay: UnsafeMutablePointer<UInt8>,
        width: Int,
        centerX: Double, centerY: Double,
        radius: Double, inner: Double,
        x0: Int, y0: Int, x1: Int, y1: Int,
        paintsDepth: Bool, eraseDepth: Bool,
        frameDepth: Float, depthDisplayScale: Float
    ) {
        let innerSq = inner * inner
        let workingBox = UncheckedSendable(working)
        let sourceBox = UncheckedSendable(source)
        let displayBox = UncheckedSendable(display)
        let wdBox = UncheckedSendable(workingDepth)
        let odBox = UncheckedSendable(originalDepth)
        let ddBox = UncheckedSendable(depthDisplay)
        let paintRow: @Sendable (Int) -> Void = { y in
            let working = workingBox.value, source = sourceBox.value
            let display = displayBox.value
            let wd = wdBox.value, od = odBox.value, dd = ddBox.value
            let dy = Double(y) - centerY
            let dySq = dy * dy
            guard dySq <= radius * radius else { return }
            // Row extent from the circle equation: the loop never visits
            // the bounding square's corners, and pixels in the hard core
            // skip the square root entirely.
            let chord = (radius * radius - dySq).squareRoot()
            let xLo = max(x0, Int((centerX - chord).rounded(.up)))
            let xHi = min(x1, Int((centerX + chord).rounded(.down)))
            guard xLo <= xHi else { return }
            for x in xLo...xHi {
                let dx = Double(x) - centerX
                let dSq = dx * dx + dySq
                let t: Double
                if dSq <= innerSq || radius <= inner {
                    t = 1
                } else {
                    let d = dSq.squareRoot()
                    t = min(max((radius - d) / (radius - inner), 0), 1)
                }
                let pi = y * width + x
                let sv = hfLoadRGBA(source, pi * 4)
                let alpha = Float(t * t * (3 - 2 * t)) * sv.w
                guard alpha > 0.003 else { continue }
                let dv = hfLoadRGBA(working, pi * 4)
                // d·(1−α) + s·α, one vector op per pixel.
                var out = dv * (1 - alpha) + sv * alpha
                out.w = 1
                hfStoreRGBA(working, pi * 4, out)
                let scaled = hfMin(hfMax(out, .zero), .one)
                    * 255 + SIMD4<Float>(repeating: 0.5)
                hfStoreRGBA8(display, pi * 4, scaled)
                if paintsDepth {
                    let target = eraseDepth ? od[pi] : frameDepth
                    let v = wd[pi] * (1 - alpha) + target * alpha
                    wd[pi] = v
                    let g = 1 - v * depthDisplayScale
                    dd[pi] = UInt8(min(max(g, 0), 1) * 255 + 0.5)
                }
            }
        }
        // Rows write disjoint memory in every plane — safe to fan out
        // (the convertToBytes structural argument). Small brushes stay
        // serial; the dispatch overhead would win.
        let rows = y1 - y0 + 1
        if rows >= 128 {
            DispatchQueue.concurrentPerform(iterations: rows) { i in
                paintRow(y0 + i)
            }
        } else {
            for y in y0...y1 { paintRow(y) }
        }
    }

    /// Restore one undo tile: copy the snapshot's pixels and depth back
    /// into the working planes and regenerate the display bytes for the
    /// tile's rect (`x0`, `y0`, `w` × `h` at canvas stride `width`).
    /// Snapshot pointers are tile-packed (stride `w`).
    public static func restoreTile(
        pixels: UnsafePointer<Float16>,
        depth: UnsafePointer<Float>,
        working: UnsafeMutablePointer<Float16>,
        display: UnsafeMutablePointer<UInt8>,
        workingDepth: UnsafeMutablePointer<Float>,
        depthDisplay: UnsafeMutablePointer<UInt8>,
        width: Int, x0: Int, y0: Int, w: Int, h: Int,
        depthDisplayScale: Float
    ) {
        for row in 0..<h {
            let dstStart = ((y0 + row) * width + x0) * 4
            let srcStart = row * w * 4
            for i in 0..<(w * 4) {
                let v = pixels[srcStart + i]
                working[dstStart + i] = v
                display[dstStart + i] = UInt8(min(max(Float(v), 0), 1) * 255 + 0.5)
            }
        }
        for row in 0..<h {
            let dstStart = (y0 + row) * width + x0
            let srcStart = row * w
            for i in 0..<w {
                let v = depth[srcStart + i]
                workingDepth[dstStart + i] = v
                let g = 1 - v * depthDisplayScale
                depthDisplay[dstStart + i] = UInt8(min(max(g, 0), 1) * 255 + 0.5)
            }
        }
    }

    /// f16 pixels → RGBA8 display bytes for the columns `x0..<x1` of rows
    /// `y0..<y1`. The min/max/scale arithmetic deliberately stays in
    /// Float16 — it always has, and re-deriving the same plane with f32
    /// rounding would put freshly-converted regions a byte off ones the
    /// stamp loop already wrote.
    public static func convertToBytes(
        pixels: UnsafePointer<Float16>,
        into bytes: UnsafeMutablePointer<UInt8>,
        width: Int, x0: Int, x1: Int, y0: Int, y1: Int
    ) {
        let srcBox = UncheckedSendable(pixels)
        let dstBox = UncheckedSendable(bytes)
        DispatchQueue.concurrentPerform(iterations: y1 - y0) { row in
            let src = srcBox.value, dst = dstBox.value
            let y = y0 + row
            for i in ((y * width + x0) * 4)..<((y * width + x1) * 4) {
                dst[i] = UInt8(min(max(src[i], 0), 1) * 255 + 0.5)
            }
        }
    }

    /// Depth values → visualization bytes (v = 1 − depth·scale, the
    /// DMapFusion.depthImage mapping) for the given rows.
    public static func convertDepthToBytes(
        depth: UnsafePointer<Float>, scale: Float,
        into bytes: UnsafeMutablePointer<UInt8>,
        width: Int, rows: Range<Int>
    ) {
        let srcBox = UncheckedSendable(depth)
        let dstBox = UncheckedSendable(bytes)
        DispatchQueue.concurrentPerform(iterations: rows.count) { row in
            let src = srcBox.value, dst = dstBox.value
            let y = rows.lowerBound + row
            for i in (y * width)..<((y + 1) * width) {
                let v = 1 - src[i] * scale
                dst[i] = UInt8(min(max(v, 0), 1) * 255 + 0.5)
            }
        }
    }
}
