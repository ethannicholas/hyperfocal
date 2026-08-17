import Foundation
#if canImport(simd)
import simd
#endif

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
        /// Dark textured object over a near-white far background — the
        /// sign-inverted contamination case: the backdrop's bloom spills
        /// INTO the dark subject, so this measures whether the debloom
        /// family defends a subject the scene-relative "near-black" cut
        /// claims. (Measured 2026-08-17: keep-darkest is the correct
        /// defense here — darkest = least bright-contaminated — so gating
        /// the near-black arm off on bright fields costs 2.9 dB on this
        /// scene.) Pair with `flicker` to also exercise darkest-frame
        /// selection on a bright field, where un-normalized exposure makes
        /// "darkest" mean "dimmest-exposed".
        case brightObject
        /// Bright LOW-CONTRAST object over a near-white far background —
        /// white-on-white. Here defocus DIMS the subject (its faint bright
        /// texture blurs away against the bright field), so a darkest-frame
        /// fallback selects the blurriest rendition: the polarity where
        /// keep-darkest damages instead of defends. This is the scene an
        /// absolute focus threshold fails — the subject's fine energy never
        /// clears a cut calibrated on high-contrast content, so the gated
        /// coarse levels never see that it is sharp.
        case whiteOnWhite
        /// The plane scene with a lit, textured near layer the focus sweep
        /// never reaches (the stack starts past its nearest structure). The
        /// ground truth renders that layer at the FIRST frame's focus — the
        /// least-blurred rendition physics permits is the correct fused
        /// output — so regional frame commitment scores high here and noisy
        /// per-cell depth scores low.
        case foreground
    }

    public struct Options {
        public var width: Int
        public var height: Int
        public var frames: Int
        public var maxBlur: Float      // defocus sigma at depth extreme, in pixels
        public var breathing: Float    // total scale change across the ramp (e.g. 0.02 = 2%)
        public var jitter: Float       // max translation per frame, in pixels
        public var flicker: Float      // exposure flicker amplitude (0.1 = ±10% gain)
        /// Per-pixel Gaussian sensor noise sigma in linear light, applied
        /// independently per channel and per frame (0 = noiseless). The CI
        /// PSNR gates were historically blind to every noise-driven failure
        /// — and never-focused-region discriminators calibrated on real
        /// stacks NEED a noise floor to read a gentle energy decline the way
        /// real sensors deliver one: a noiseless defocused layer's fine
        /// energy either vanishes below f16 quantization or falls too
        /// steeply, never the measured 2–4:1.
        public var noise: Float
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
                    flicker: Float = 0, noise: Float = 0, scene: Scene = .plane,
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
            self.noise = noise
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
        img.pixels.withUnsafeMutableBufferPointer { pxBuf in
            let px = pxBuf.baseAddress!
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
                    let v = SIMD4<Float>(min(max(rgb.x, 0), 1),
                                         min(max(rgb.y, 0), 1),
                                         min(max(rgb.z, 0), 1), 1)
                    hfStoreRGBA(px, (y * width + x) * 4, v)
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
                    let h = Float16(bright)
                    img.pixels[pi] = h
                    img.pixels[pi + 1] = h
                    img.pixels[pi + 2] = h
                }
            }
        }
        return img
    }

    /// Adds deterministic per-pixel luminance detail (hash noise, ±amplitude)
    /// to a texture. The octave stack's finest cells are ~9 px at the default
    /// synth size — smooth at pixel scale — so an in-focus cell carries
    /// almost no finest-level energy and scale-free focus discriminators
    /// read the whole scene as never-focusing glint-speckle. Real macro
    /// texture is dense at pixel scale; this restores that. Scene detail,
    /// not sensor noise: it lives in the ground truth and defocuses with it.
    static func addPixelDetail(_ img: inout ImageBuffer, amplitude: Float, seed: UInt64) {
        let w = img.width, h = img.height
        img.pixels.withUnsafeMutableBufferPointer { pxBuf in
            let px = pxBuf.baseAddress!
            DispatchQueue.concurrentPerform(iterations: h) { y in
                for x in 0..<w {
                    var rng = SplitMix64(state: seed &+ UInt64(y * w + x))
                    let n = (rng.nextFloat() * 2 - 1) * amplitude
                    let pi = (y * w + x) * 4
                    var v = hfLoadRGBA(px, pi) + SIMD4<Float>(n, n, n, 0)
                    v = v.clamped(lowerBound: .zero, upperBound: .one)
                    hfStoreRGBA(px, pi, v)
                }
            }
        }
    }

    /// Per-pixel, per-channel Gaussian sensor noise in linear light
    /// (Box–Muller over the hash stream), clipped to [0, 1] like a sensor.
    static func addSensorNoise(_ img: inout ImageBuffer, sigma: Float, seed: UInt64) {
        let w = img.width, h = img.height
        img.pixels.withUnsafeMutableBufferPointer { pxBuf in
            let px = pxBuf.baseAddress!
            DispatchQueue.concurrentPerform(iterations: h) { y in
                for x in 0..<w {
                    var rng = SplitMix64(state: seed &+ UInt64(y * w + x))
                    let u1 = max(rng.nextFloat(), 1e-7)
                    let u2 = rng.nextFloat()
                    let u3 = max(rng.nextFloat(), 1e-7)
                    let u4 = rng.nextFloat()
                    let r1 = (-2 * Foundation.log(u1)).squareRoot() * sigma
                    let r2 = (-2 * Foundation.log(u3)).squareRoot() * sigma
                    let n = SIMD4<Float>(r1 * Foundation.cos(2 * .pi * u2),
                                         r1 * Foundation.sin(2 * .pi * u2),
                                         r2 * Foundation.cos(2 * .pi * u4), 0)
                    let pi = (y * w + x) * 4
                    let v = (hfLoadRGBA(px, pi) + n)
                        .clamped(lowerBound: .zero, upperBound: .one)
                    hfStoreRGBA(px, pi, v)
                }
            }
        }
    }

    /// Depth plane in [0, 1]: mostly left-to-right ramp with a slight vertical tilt.
    static func depth(x: Int, y: Int, width: Int, height: Int) -> Float {
        0.75 * Float(x) / Float(width - 1) + 0.25 * Float(y) / Float(height - 1)
    }

    /// Depth of the `.foreground` scene's near layer. Focus positions span
    /// [0, 1], so a negative depth keeps the layer defocused in every frame,
    /// most gently in frame 0 — never sharp, but with the measurable
    /// frame-0 energy bump of a real beyond-sweep layer. Too deep and the
    /// blur pushes the layer's fine energy below f16 frame quantization,
    /// leaving a flat noise curve no regional mechanism can (or should)
    /// commit — real stacks keep the bump measurable because residual
    /// signal rides above the sensor noise floor.
    static let foregroundDepth: Float = -0.45

    /// The `.plane` frame renderer: per-pixel depth-dependent defocus,
    /// interpolated from pre-blurred sigma buckets.
    static func planeFrameMaker(tex: ImageBuffer, maxBlur: Float,
                                log: ((String) -> Void)?) -> (Float) -> ImageBuffer {
        let w = tex.width, h = tex.height
        let bucketStep: Float = 0.75
        let bucketCount = Int((maxBlur / bucketStep).rounded(.up)) + 1
        // Buckets live in ONE contiguous plane array indexed by
        // `bucket * planeCount + i`, so the per-pixel interpolation below
        // needs a single base pointer instead of escaping one per bucket
        // out of a `withUnsafeBufferPointer` (which would be UB).
        let planeCount = w * h * 4
        var buckets = [Float16](repeating: 0, count: (bucketCount + 1) * planeCount)
        buckets.replaceSubrange(0..<planeCount, with: tex.pixels)
        for b in 1...bucketCount {
            let sigma = Float(b) * bucketStep
            let k = Filters.gaussianKernel(sigma: sigma)
            let blurred = Filters.convolveSeparableRGBA(tex, kernel: k)
            buckets.replaceSubrange(b * planeCount..<(b + 1) * planeCount,
                                    with: blurred.pixels)
        }
        log?("\(bucketCount + 1) blur buckets prepared")
        return { focus in
            var frame = ImageBuffer(width: w, height: h)
            buckets.withUnsafeBufferPointer { bkBuf in
                let bk = bkBuf.baseAddress!
                frame.pixels.withUnsafeMutableBufferPointer { pxBuf in
                    let px = pxBuf.baseAddress!
                    DispatchQueue.concurrentPerform(iterations: h) { y in
                        for x in 0..<w {
                            let sigma = maxBlur * abs(depth(x: x, y: y, width: w, height: h) - focus)
                            let fb = sigma / bucketStep
                            let b0 = min(Int(fb), bucketCount - 1)
                            let b1 = min(b0 + 1, bucketCount)
                            let t = fb - Float(b0)
                            let pi = (y * w + x) * 4
                            hfStoreRGBA(px, pi,
                                        hfLoadRGBA(bk, b0 * planeCount + pi) * (1 - t)
                                      + hfLoadRGBA(bk, b1 * planeCount + pi) * t)
                        }
                    }
                }
            }
            return frame
        }
    }

    /// A premultiplied subject layer: `tex` remapped through `map` (straight
    /// opaque RGBA in, straight RGBA out), then masked by a soft-edged
    /// ellipse (~2 px feather) that premultiplies color and sets alpha.
    static func ellipseLayer(tex: ImageBuffer,
                             map: @escaping (SIMD4<Float>) -> SIMD4<Float>,
                             cx: Float, cy: Float,
                             rx: Float, ry: Float) -> ImageBuffer {
        let w = tex.width, h = tex.height
        var subject = ImageBuffer(width: w, height: h)
        subject.pixels.withUnsafeMutableBufferPointer { pxBuf in
            let px = pxBuf.baseAddress!
            tex.pixels.withUnsafeBufferPointer { tpBuf in
                let tp = tpBuf.baseAddress!
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    for x in 0..<w {
                        let dx = (Float(x) - cx) / rx
                        let dy = (Float(y) - cy) / ry
                        let d = (dx * dx + dy * dy).squareRoot()
                        let m = min(max((1.01 - d) / 0.02, 0), 1)  // ~2 px soft edge
                        let pi = (y * w + x) * 4
                        var v = map(hfLoadRGBA(tp, pi)) * m
                        v.w = m
                        hfStoreRGBA(px, pi, v)
                    }
                }
            }
        }
        return subject
    }

    /// Premultiplied-alpha over: fg.rgb + bg.rgb * (1 - fg.a), opaque result.
    static func composite(_ fg: ImageBuffer, over bg: ImageBuffer) -> ImageBuffer {
        var out = ImageBuffer(width: fg.width, height: fg.height)
        fg.pixels.withUnsafeBufferPointer { fBuf in
            let f = fBuf.baseAddress!
            bg.pixels.withUnsafeBufferPointer { bBuf in
                let b = bBuf.baseAddress!
                out.pixels.withUnsafeMutableBufferPointer { oBuf in
                    let o = oBuf.baseAddress!
                    DispatchQueue.concurrentPerform(iterations: fg.height) { y in
                        let row = y * fg.width * 4
                        var pi = row
                        while pi < row + fg.width * 4 {
                            let fp = hfLoadRGBA(f, pi)
                            var v = fp + hfLoadRGBA(b, pi) * (1 - fp.w)
                            v.w = 1
                            hfStoreRGBA(o, pi, v)
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
            makeFrame = planeFrameMaker(tex: tex, maxBlur: options.maxBlur, log: log)

        case .object, .brightObject, .whiteOnWhite:
            // Textured subject (flat, at depth 0.3) premultiplied by a soft
            // ellipse mask, over a textured far background at depth 1.0.
            // `.object`: bright subject over near-black — defocused frames
            // spill subject glow onto the background (the halo case).
            // `.brightObject`: the sign inversion — dark subject (mostly
            // under a scene-relative "near-black" cut, but carrying real
            // texture) over a near-white sweep with the SAME backdrop
            // contrast, so mechanisms calibrated on dark backdrops meet the
            // field they were not calibrated for.
            // `.whiteOnWhite`: bright low-contrast subject over the same
            // near-white sweep — the subject's fine energy sits far below
            // any absolute focus cut calibrated on high-contrast content,
            // and defocus DIMS it, so darkest-frame fallbacks pick blur.
            let tex = groundTruth(width: w, height: h, seed: seed)
            var bg = groundTruth(width: w, height: h, seed: seed &+ 7)
            let subjectMap: (SIMD4<Float>) -> SIMD4<Float>
            switch options.scene {
            case .object:
                bg.scaleRGB(by: 0.05)
                subjectMap = { $0 }
            case .brightObject:
                bg.affineRGB(scale: 0.05, offset: 0.95)
                subjectMap = { v in
                    SIMD4<Float>(0.02, 0.02, 0.02, 0) + v * SIMD4<Float>(0.18, 0.18, 0.18, 1)
                }
            default:
                bg.affineRGB(scale: 0.05, offset: 0.95)
                // 0.80-0.95: bright, contrast 0.15 — real texture, but fine
                // energy well under high-contrast calibrations.
                subjectMap = { v in
                    SIMD4<Float>(0.80, 0.80, 0.80, 0) + v * SIMD4<Float>(0.15, 0.15, 0.15, 1)
                }
            }
            let subject = ellipseLayer(tex: tex, map: subjectMap,
                                       cx: Float(w) * 0.5, cy: Float(h) * 0.52,
                                       rx: Float(w) * 0.28, ry: Float(h) * 0.34)
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

        case .foreground:
            // The plane scene, occluded across its bottom by a lit
            // textured layer at `foregroundDepth` — in FRONT of every focus
            // position, so no frame ever renders it sharp and its energy
            // argmax is frame 0 (the near stack boundary). The layer is
            // deliberately deep enough that even frame 0 is heavily blurred:
            // in a never-focused region per-cell depth is noise, and the only
            // correct output is one committed frame's rendition. The ground
            // truth therefore composites the layer at frame 0's defocus over
            // the sharp plane — fusion that commits the region to its edge
            // frame matches it; fusion that blends noisy per-cell selections
            // across the sweep does not.
            var tex = groundTruth(width: w, height: h, seed: seed)
            addPixelDetail(&tex, amplitude: 0.2, seed: seed &+ 21)
            var fgTex = groundTruth(width: w, height: h, seed: seed &+ 13)
            addPixelDetail(&fgTex, amplitude: 0.2, seed: seed &+ 34)
            // The layer is a bottom band whose single (top) edge is aligned
            // to the fusion engines' 64-px energy-block grid (8-px cells ×
            // 8-cell blocks) and feathered ~2 px. At real resolutions a
            // never-focused region's boundary blocks are a negligible
            // fraction; at synth scale a misaligned edge puts pure sharp-
            // plane cells inside majority-member blocks, and their energy
            // (tens of times the defocused layer's) buries the region's
            // frame-0 mass-curve bump under mid-sweep boundary humps.
            let bandTop = 64 * Int(Float(h) * 0.64 / 64)
            // A block-aligned focusing POCKET punched through the band: the
            // plane shows through and focuses mid-sweep, so the region's
            // never-focuses component test (a median) still passes around it
            // while the pocket carries genuinely focusing sub-content — the
            // class the governance review's per-cell focusing veto exists to
            // protect ("sharp sub-content replaced by blur"). A regional
            // mechanism that hole-fills or commits the pocket paints real
            // mid-sweep sharpness with the edge frame's defocus, and the
            // scene's PSNR moves; a per-cell veto leaves the pocket with
            // per-coefficient selection and heals it.
            let px0 = 64 * Int(Float(w) * 0.57 / 64), px1 = px0 + 128
            let py0 = 64 * Int(Float(h) * 0.75 / 64), py1 = py0 + 64
            // The plane seen through the pocket is DIMMED (deep background
            // through a hole in the near layer, still lit and textured, its
            // energy in the moderate ratio band): dim enough to join the
            // lit-governance membership like the real class does, sharp
            // late in the sweep — so an unprotected regional commitment
            // paints it with the edge frame's defocus, and the per-cell
            // focusing veto is what heals it.
            tex.pixels.withUnsafeMutableBufferPointer { pxBuf in
                let px = pxBuf.baseAddress!
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    let py = min(max((Float(y) - Float(py0)) / 2, 0), 1)
                        * min(max((Float(py1) - Float(y)) / 2, 0), 1)
                    guard py > 0 else { return }
                    for x in 0..<w {
                        let pxm = min(max((Float(x) - Float(px0)) / 2, 0), 1)
                            * min(max((Float(px1) - Float(x)) / 2, 0), 1)
                        let dim = 1 - 0.75 * pxm * py
                        guard dim < 1 else { continue }
                        let pi = (y * w + x) * 4
                        var v = hfLoadRGBA(px, pi)
                        v = SIMD4<Float>(v.x * dim, v.y * dim, v.z * dim, v.w)
                        hfStoreRGBA(px, pi, v)
                    }
                }
            }
            var fg = fgTex
            fg.pixels.withUnsafeMutableBufferPointer { pxBuf in
                let px = pxBuf.baseAddress!
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    let band = min(max((Float(y) - Float(bandTop)) / 2, 0), 1)
                    let pocketY = min(max((Float(y) - Float(py0)) / 2, 0), 1)
                        * min(max((Float(py1) - Float(y)) / 2, 0), 1)
                    var pi = y * w * 4
                    for x in 0..<w {
                        let pocketX = min(max((Float(x) - Float(px0)) / 2, 0), 1)
                            * min(max((Float(px1) - Float(x)) / 2, 0), 1)
                        let m = band * (1 - pocketX * pocketY)
                        var v = hfLoadRGBA(px, pi) * m
                        v.w = m
                        hfStoreRGBA(px, pi, v)
                        pi += 4
                    }
                }
            }
            let maxBlur = options.maxBlur
            let blurFg = { (focus: Float) -> ImageBuffer in
                let sigma = maxBlur * (focus - foregroundDepth)
                return Filters.convolveSeparableRGBA(fg, kernel: Filters.gaussianKernel(sigma: sigma))
            }
            truth = composite(blurFg(0), over: tex)
            let plane = planeFrameMaker(tex: tex, maxBlur: maxBlur, log: log)
            makeFrame = { focus in composite(blurFg(focus), over: plane(focus)) }
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
                frame.scaleRGB(by: 1 + options.flicker * sin(Float(i) * 2.399))
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

            // Sensor noise is the last thing a capture applies — after
            // optics (blur), exposure (flicker/misfire), and motion (warp).
            // Per-frame seeds keep it decorrelated across the stack, the
            // property every noise-driven failure mode hinges on.
            if options.noise > 0 {
                addSensorNoise(&frame, sigma: options.noise,
                               seed: seed &+ 0xC0FFEE &+ UInt64(i) &* 0x9E3779B97F4A7C15)
            }

            let url = outDir.appendingPathComponent(String(format: "frame_%03d.%@", i, frameExtension))
            let stamp = options.captureStart.map { start in
                StackSplitter.exifFormatter.string(
                    from: start.addingTimeInterval(Double(i) * options.captureSpacing))
            }
            try ImageFile.save(frame, to: url, dateTimeOriginal: stamp)
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
        img.pixels.withUnsafeBufferPointer { srcBuf in
            let src = srcBuf.baseAddress!
            out.pixels.withUnsafeMutableBufferPointer { dstBuf in
                let dst = dstBuf.baseAddress!
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    for x in 0..<w {
                        let sx = Float(x) + shift + amplitude * sin(Float(y) * 2 * .pi / wavelength)
                        let sy = Float(y) + amplitude * cos(Float(x) * 2 * .pi / wavelength)
                        let cx = min(max(sx, 0), Float(w - 1))
                        let cy = min(max(sy, 0), Float(h - 1))
                        let x0 = min(Int(cx), w - 2), y0 = min(Int(cy), h - 2)
                        let tx = cx - Float(x0), ty = cy - Float(y0)
                        let i00 = hfLoadRGBA(src, (y0 * w + x0) * 4)
                        let i10 = hfLoadRGBA(src, (y0 * w + x0 + 1) * 4)
                        let i01 = hfLoadRGBA(src, ((y0 + 1) * w + x0) * 4)
                        let i11 = hfLoadRGBA(src, ((y0 + 1) * w + x0 + 1) * 4)
                        var v = (i00 * (1 - tx) + i10 * tx) * (1 - ty)
                              + (i01 * (1 - tx) + i11 * tx) * ty
                        v.w = 1
                        hfStoreRGBA(dst, (y * w + x) * 4, v)
                    }
                }
            }
        }
        return out
    }
}
