import Foundation
import ImageIO
import simd

/// Generates synthetic focus stacks with known ground truth, for validating the
/// pipeline end to end: a detailed texture over a tilted depth plane, per-frame
/// depth-dependent defocus blur, plus focus breathing (scale) and jitter
/// (translation) to exercise alignment.
public enum SynthStack {

    public enum Scene: String, CaseIterable {
        /// Textured plane tilted through the focus range — every pixel is sharp in
        /// some frame. Exercises alignment and fusion quality.
        case plane
        /// Bright textured object at one depth over a near-black far background —
        /// the halo torture test (defocus spill onto featureless background).
        case object
    }

    public struct Options {
        public var width: Int
        public var height: Int
        public var frames: Int
        public var maxBlur: Float      // defocus sigma at depth extreme, in pixels
        public var breathing: Float    // total scale change across the ramp (e.g. 0.02 = 2%)
        public var jitter: Float       // max translation per frame, in pixels
        public var flicker: Float      // exposure flicker amplitude (0.1 = ±10% gain)
        public var scene: Scene
        /// Darken this frame to ~2% — a synthetic flash misfire. Exercises
        /// bad-frame exposure detection.
        public var misfireFrame: Int?
        /// Displace this frame non-rigidly (wave + large shift) — a synthetic
        /// bumped rail / wind gust that no homography can align. Exercises
        /// bad-frame residual detection.
        public var bumpFrame: Int?
        /// Stamp EXIF DateTimeOriginal per frame, starting here and advancing
        /// `captureSpacing` per frame — makes synth stacks splittable by
        /// capture-time gap (session/batch tests).
        public var captureStart: Date?
        public var captureSpacing: TimeInterval

        public init(width: Int = 900, height: Int = 600, frames: Int = 15,
                    maxBlur: Float = 6, breathing: Float = 0.02, jitter: Float = 3,
                    flicker: Float = 0, scene: Scene = .plane,
                    misfireFrame: Int? = nil, bumpFrame: Int? = nil,
                    captureStart: Date? = nil, captureSpacing: TimeInterval = 1) {
            self.width = width
            self.height = height
            // Odd frame count so the middle (reference) frame can have an identity transform.
            self.frames = frames % 2 == 0 ? frames + 1 : frames
            self.maxBlur = maxBlur
            self.breathing = breathing
            self.jitter = jitter
            self.flicker = flicker
            self.scene = scene
            self.misfireFrame = misfireFrame
            self.bumpFrame = bumpFrame
            self.captureStart = captureStart
            self.captureSpacing = captureSpacing
        }
    }

    struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func nextFloat() -> Float {
            Float(next() >> 40) / Float(1 << 24)
        }
    }

    /// Multi-octave value noise: dense detail at every scale, so every depth slice
    /// has features for both registration and sharpness measurement.
    static func groundTruth(width: Int, height: Int, seed: UInt64) -> ImageBuffer {
        var rng = SplitMix64(state: seed)
        let octaves = 5
        var grids = [[Float]]()
        var gridSizes = [(Int, Int)]()
        for o in 0..<octaves {
            let cells = 6 << o
            let gw = cells + 2, gh = cells + 2
            var g = [Float](repeating: 0, count: gw * gh * 3)
            for i in g.indices { g[i] = rng.nextFloat() }
            grids.append(g)
            gridSizes.append((gw, gh))
        }

        var img = ImageBuffer(width: width, height: height)
        img.pixels.withUnsafeMutableBufferPointer { px in
            DispatchQueue.concurrentPerform(iterations: height) { y in
                for x in 0..<width {
                    var rgb = SIMD3<Float>(0.5, 0.5, 0.5)
                    var amp: Float = 0.4
                    for o in 0..<octaves {
                        let (gw, gh) = gridSizes[o]
                        let cells = Float(6 << o)
                        let fx = Float(x) / Float(width) * cells
                        let fy = Float(y) / Float(height) * cells
                        let x0 = Int(fx), y0 = Int(fy)
                        let wx = fx - Float(x0), wy = fy - Float(y0)
                        let sx = wx * wx * (3 - 2 * wx)
                        let sy = wy * wy * (3 - 2 * wy)
                        let cx0 = min(x0, gw - 1), cx1 = min(x0 + 1, gw - 1)
                        let cy0 = min(y0, gh - 1), cy1 = min(y0 + 1, gh - 1)
                        let grid = grids[o]
                        for c in 0..<3 {
                            let i00: Float = grid[(cy0 * gw + cx0) * 3 + c]
                            let i10: Float = grid[(cy0 * gw + cx1) * 3 + c]
                            let i01: Float = grid[(cy1 * gw + cx0) * 3 + c]
                            let i11: Float = grid[(cy1 * gw + cx1) * 3 + c]
                            let top: Float = i00 * (1 - sx) + i10 * sx
                            let bot: Float = i01 * (1 - sx) + i11 * sx
                            let v: Float = top * (1 - sy) + bot * sy
                            rgb[c] += (v - 0.5) * amp
                        }
                        amp *= 0.55
                    }
                    let pi = (y * width + x) * 4
                    px[pi] = min(max(rgb.x, 0), 1)
                    px[pi + 1] = min(max(rgb.y, 0), 1)
                    px[pi + 2] = min(max(rgb.z, 0), 1)
                    px[pi + 3] = 1
                }
            }
        }

        // Scatter hard-edged speckles for unambiguous fine detail.
        for _ in 0..<600 {
            let cx = Int(rng.nextFloat() * Float(width - 4)) + 2
            let cy = Int(rng.nextFloat() * Float(height - 4)) + 2
            let bright: Float = rng.nextFloat() > 0.5 ? 0.95 : 0.05
            let r = rng.nextFloat() > 0.7 ? 2 : 1
            for dy in -r...r {
                for dx in -r...r where dx * dx + dy * dy <= r * r {
                    let pi = ((cy + dy) * width + (cx + dx)) * 4
                    img.pixels[pi] = bright
                    img.pixels[pi + 1] = bright
                    img.pixels[pi + 2] = bright
                }
            }
        }
        return img
    }

    /// Depth plane in [0, 1]: mostly left-to-right ramp with a slight vertical tilt.
    static func depth(x: Int, y: Int, width: Int, height: Int) -> Float {
        0.75 * Float(x) / Float(width - 1) + 0.25 * Float(y) / Float(height - 1)
    }

    /// Premultiplied-alpha over: fg.rgb + bg.rgb * (1 - fg.a), opaque result.
    static func composite(_ fg: ImageBuffer, over bg: ImageBuffer) -> ImageBuffer {
        var out = ImageBuffer(width: fg.width, height: fg.height)
        fg.pixels.withUnsafeBufferPointer { f in
            bg.pixels.withUnsafeBufferPointer { b in
                out.pixels.withUnsafeMutableBufferPointer { o in
                    DispatchQueue.concurrentPerform(iterations: fg.height) { y in
                        let row = y * fg.width * 4
                        var pi = row
                        while pi < row + fg.width * 4 {
                            let a = f[pi + 3]
                            o[pi] = f[pi] + b[pi] * (1 - a)
                            o[pi + 1] = f[pi + 1] + b[pi + 1] * (1 - a)
                            o[pi + 2] = f[pi + 2] + b[pi + 2] * (1 - a)
                            o[pi + 3] = 1
                            pi += 4
                        }
                    }
                }
            }
        }
        return out
    }

    public static func generate(options: Options, outDir: URL, seed: UInt64 = 42,
                                frameExtension: String = "tif",
                                log: ((String) -> Void)? = nil) throws -> (truthURL: URL, frameURLs: [URL]) {
        let fm = FileManager.default
        try fm.createDirectory(at: outDir, withIntermediateDirectories: true)

        let w = options.width, h = options.height, n = options.frames
        let truth: ImageBuffer
        let makeFrame: (Float) -> ImageBuffer

        switch options.scene {
        case .plane:
            let tex = groundTruth(width: w, height: h, seed: seed)
            truth = tex
            // Pre-blurred versions at bucketed sigmas; per-pixel blur interpolates buckets.
            let bucketStep: Float = 0.75
            let bucketCount = Int((options.maxBlur / bucketStep).rounded(.up)) + 1
            var buckets = [tex]
            for b in 1...bucketCount {
                let sigma = Float(b) * bucketStep
                let k = Filters.gaussianKernel(sigma: sigma)
                buckets.append(Filters.convolveSeparableRGBA(tex, kernel: k))
            }
            log?("\(buckets.count) blur buckets prepared")
            let maxBlur = options.maxBlur
            makeFrame = { focus in
                var frame = ImageBuffer(width: w, height: h)
                frame.pixels.withUnsafeMutableBufferPointer { px in
                    DispatchQueue.concurrentPerform(iterations: h) { y in
                        for x in 0..<w {
                            let sigma = maxBlur * abs(depth(x: x, y: y, width: w, height: h) - focus)
                            let fb = sigma / bucketStep
                            let b0 = min(Int(fb), bucketCount - 1)
                            let b1 = min(b0 + 1, bucketCount)
                            let t = fb - Float(b0)
                            let pi = (y * w + x) * 4
                            for c in 0..<4 {
                                px[pi + c] = buckets[b0].pixels[pi + c] * (1 - t)
                                    + buckets[b1].pixels[pi + c] * t
                            }
                        }
                    }
                }
                return frame
            }

        case .object:
            // Bright textured subject (flat, at depth 0.3) premultiplied by a soft
            // ellipse mask, over a near-black textured background at depth 1.0.
            // Defocused frames spill subject glow onto the background — the halo case.
            let tex = groundTruth(width: w, height: h, seed: seed)
            var bg = groundTruth(width: w, height: h, seed: seed &+ 7)
            for i in bg.pixels.indices where i % 4 != 3 { bg.pixels[i] *= 0.05 }

            var subject = ImageBuffer(width: w, height: h)
            let cx = Float(w) * 0.5, cy = Float(h) * 0.52
            let rx = Float(w) * 0.28, ry = Float(h) * 0.34
            subject.pixels.withUnsafeMutableBufferPointer { px in
                tex.pixels.withUnsafeBufferPointer { tp in
                    DispatchQueue.concurrentPerform(iterations: h) { y in
                        for x in 0..<w {
                            let dx = (Float(x) - cx) / rx
                            let dy = (Float(y) - cy) / ry
                            let d = (dx * dx + dy * dy).squareRoot()
                            let m = min(max((1.01 - d) / 0.02, 0), 1)  // ~2 px soft edge
                            let pi = (y * w + x) * 4
                            px[pi] = tp[pi] * m
                            px[pi + 1] = tp[pi + 1] * m
                            px[pi + 2] = tp[pi + 2] * m
                            px[pi + 3] = m
                        }
                    }
                }
            }
            truth = composite(subject, over: bg)
            let maxBlur = options.maxBlur
            makeFrame = { focus in
                let sigmaSubject = maxBlur * abs(0.3 - focus)
                let sigmaBackground = maxBlur * abs(1.0 - focus)
                let blurredSubject = sigmaSubject > 0.01
                    ? Filters.convolveSeparableRGBA(subject, kernel: Filters.gaussianKernel(sigma: sigmaSubject))
                    : subject
                let blurredBg = sigmaBackground > 0.01
                    ? Filters.convolveSeparableRGBA(bg, kernel: Filters.gaussianKernel(sigma: sigmaBackground))
                    : bg
                return composite(blurredSubject, over: blurredBg)
            }
        }

        let truthURL = outDir.appendingPathComponent("ground_truth.tif")
        try ImageFile.save(truth, to: truthURL)
        log?("ground truth written")

        var rng = SplitMix64(state: seed &+ 999)
        var frameURLs = [URL]()
        let refIndex = n / 2
        let center = SIMD2<Float>(Float(w) / 2, Float(h) / 2)

        for i in 0..<n {
            let focus = Float(i) / Float(n - 1)
            var frame = makeFrame(focus)

            // Exposure flicker: a deterministic pseudo-random gain per frame
            // (all frames, including the reference — real flicker spares nobody).
            if options.flicker != 0 {
                let gain = 1 + options.flicker * sin(Float(i) * 2.399)
                for pi in frame.pixels.indices where pi % 4 != 3 {
                    frame.pixels[pi] *= gain
                }
            }

            // Focus breathing + jitter; the reference frame stays untransformed so the
            // aligned result is directly comparable to ground truth.
            let jx = (rng.nextFloat() - 0.5) * 2 * options.jitter
            let jy = (rng.nextFloat() - 0.5) * 2 * options.jitter
            if i != refIndex {
                let scale = 1 + options.breathing * (focus - 0.5)
                let m = Warp.similarity(scale: scale, rotation: 0,
                                        translation: SIMD2<Float>(jx, jy), center: center)
                // frame = warp of truth-space image: output (frame) → source (truth) = m⁻¹
                frame = Warp.apply(frame, outputToSource: m.inverse, outWidth: w, outHeight: h)
            }

            // Sabotage (bad-frame detection tests). The reference frame is
            // never sabotaged — the pipeline must keep a comparable output.
            if i == options.misfireFrame, i != refIndex {
                for pi in frame.pixels.indices where pi % 4 != 3 {
                    frame.pixels[pi] *= 0.02
                }
            }
            if i == options.bumpFrame, i != refIndex {
                frame = bumped(frame)
            }

            let url = outDir.appendingPathComponent(String(format: "frame_%03d.%@", i, frameExtension))
            var extra: [CFString: Any]? = nil
            if let start = options.captureStart {
                let stamp = StackSplitter.exifFormatter.string(
                    from: start.addingTimeInterval(Double(i) * options.captureSpacing))
                extra = [kCGImagePropertyExifDictionary:
                            [kCGImagePropertyExifDateTimeOriginal: stamp]]
            }
            try ImageFile.save(frame, to: url, extraProperties: extra)
            frameURLs.append(url)
            log?("frame \(i + 1)/\(n) (focus \(String(format: "%.2f", focus)))")
        }
        return (truthURL, frameURLs)
    }

    /// A "bumped rail" frame: a sinusoidal displacement field plus a large
    /// shift. The wave is non-rigid, so the best-fitting homography still
    /// leaves a residual several times the stack's normal frame-to-frame
    /// difference — which is exactly what quality detection keys on.
    static func bumped(_ img: ImageBuffer, amplitude: Float = 6, shift: Float = 40) -> ImageBuffer {
        let w = img.width, h = img.height
        let wavelength = Float(h) / 2.5
        var out = ImageBuffer(width: w, height: h)
        img.pixels.withUnsafeBufferPointer { src in
            out.pixels.withUnsafeMutableBufferPointer { dst in
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    for x in 0..<w {
                        let sx = Float(x) + shift + amplitude * sin(Float(y) * 2 * .pi / wavelength)
                        let sy = Float(y) + amplitude * cos(Float(x) * 2 * .pi / wavelength)
                        let cx = min(max(sx, 0), Float(w - 1))
                        let cy = min(max(sy, 0), Float(h - 1))
                        let x0 = min(Int(cx), w - 2), y0 = min(Int(cy), h - 2)
                        let tx = cx - Float(x0), ty = cy - Float(y0)
                        let di = (y * w + x) * 4
                        for c in 0..<3 {
                            let i00 = src[(y0 * w + x0) * 4 + c]
                            let i10 = src[(y0 * w + x0 + 1) * 4 + c]
                            let i01 = src[((y0 + 1) * w + x0) * 4 + c]
                            let i11 = src[((y0 + 1) * w + x0 + 1) * 4 + c]
                            dst[di + c] = (i00 * (1 - tx) + i10 * tx) * (1 - ty)
                                        + (i01 * (1 - tx) + i11 * tx) * ty
                        }
                        dst[di + 3] = 1
                    }
                }
            }
        }
        return out
    }
}
