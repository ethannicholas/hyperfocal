import Foundation
#if canImport(AVFoundation)
import AVFoundation
import CoreGraphics
import ImageIO
#endif

/// Zerene-style rocking animation: the fused image reprojected with a
/// per-pixel horizontal disparity proportional to the regularized depth
/// plane, swept through a seamless sine cycle and written as H.264. The
/// warp is a gather with the disparity evaluated at the *destination*
/// pixel — for rocking-scale amplitudes (a percent of the width or less)
/// that renders occlusion boundaries as gentle stretches instead of holes,
/// which reads better than any inpainting and needs none.
public enum RockingAnimation {

    /// The viewpoint's motion (Zerene's path options): a straight rock on
    /// either axis, or a circular orbit — the strongest 3D read, since no
    /// scene structure can hide parallel to the motion.
    public enum Path: String, CaseIterable, Sendable {
        case horizontal
        case vertical
        case circular

        /// Unit displacement direction at a cycle position (0...1); a full
        /// cycle always returns to its start, so every path loops
        /// seamlessly.
        func offset(at t: Double) -> (x: Double, y: Double) {
            let theta = 2 * Double.pi * t
            switch self {
            case .horizontal: return (sin(theta), 0)
            case .vertical: return (0, sin(theta))
            case .circular: return (sin(theta), cos(theta))
            }
        }
    }

    public struct Options {
        /// Output video long side, in pixels (rounded down to even for the
        /// encoder). The full-resolution fusion is box-downsampled first —
        /// nobody rocks a 45 MP video.
        public var maxSide = 1920
        public var duration = 3.0
        public var fps = 30.0
        /// Peak disparity at the depth extremes, as a fraction of the
        /// output width. 0.01 reads "gentle but alive"; 0.02 is emphatic.
        ///
        /// Depth *direction* deliberately has no option: negating the
        /// disparity is exactly a half-cycle phase shift of any of the
        /// symmetric paths (−sin θ = sin(θ+π)), so an "inverted" rocking
        /// animation is the same loop started elsewhere — verified
        /// bit-exact. Stereo pairs (a fixed per-eye offset, no cycle to
        /// hide in) are where direction will matter.
        public var amplitude = 0.01
        public var path = Path.horizontal

        public init(maxSide: Int = 1920, duration: Double = 3, fps: Double = 30,
                    amplitude: Double = 0.01, path: Path = .horizontal) {
            self.maxSide = maxSide
            self.duration = duration
            self.fps = fps
            self.amplitude = amplitude
            self.path = path
        }

        /// Pixel shift vector for a frame of the cycle.
        func shift(frame: Int, of count: Int, width: Int) -> (x: Float, y: Float) {
            let unit = path.offset(at: Double(frame) / Double(count))
            let peak = amplitude * Double(width)
            return (Float(unit.x * peak), Float(unit.y * peak))
        }
    }

    /// Writes the animation; the container comes from the URL's extension —
    /// "gif" writes an animated GIF flagged to loop forever (the only widely
    /// honored in-file loop; MP4 has no loop flag any player respects),
    /// anything else writes H.264 MP4. `image` and `depth` are
    /// full-resolution and same-sized (the fused result — tone already
    /// applied by the caller — and DMapFusion.Output.depth).
    #if canImport(AVFoundation)
    public static func write(to url: URL, image: ImageBuffer, depth: [Float],
                             options: Options = Options(),
                             log: ((String) -> Void)? = nil,
                             progress: ((Double) -> Void)? = nil,
                             cancellation: CancellationToken? = nil) throws {
        precondition(depth.count == image.width * image.height,
                     "depth plane must match the image")
        let scale = min(1.0, Double(options.maxSide) / Double(max(image.width, image.height)))
        // Even dimensions: H.264 4:2:0 subsampling requires them.
        let w = max(2, Int(Double(image.width) * scale) & ~1)
        let h = max(2, Int(Double(image.height) * scale) & ~1)
        let (base, smallDepth) = downsample(image, depth: depth, to: (w, h))
        let disparity = normalizedDisparity(smallDepth)

        let frameCount = max(2, Int(options.duration * options.fps))
        let gif = url.pathExtension.lowercased() == "gif"
        log?(String(format: "rocking: %dx%d, %d frames @ %.0f fps, amplitude %.1f%%, %@",
                    w, h, frameCount, options.fps, options.amplitude * 100,
                    gif ? "GIF" : "H.264"))

        if gif {
            try writeGIF(to: url, base: base, disparity: disparity,
                         frameCount: frameCount, options: options,
                         progress: progress, cancellation: cancellation)
            log?("wrote \(url.lastPathComponent)")
            return
        }

        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            // Frames are converted to sRGB; 709 tags are the universal
            // "plays correctly everywhere" match for that.
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
            ])
        guard writer.canAdd(input) else { throw StackError.io("animation writer rejected input") }
        writer.add(input)
        guard writer.startWriting() else {
            throw StackError.io("animation writer: \(writer.error?.localizedDescription ?? "unknown")")
        }
        writer.startSession(atSourceTime: .zero)

        var warped = ImageBuffer(width: w, height: h)
        let timescale = CMTimeScale(600)
        for frame in 0..<frameCount {
            try cancellation?.checkCancelled()
            // A full sine cycle starting and ending at zero: seamless loop.
            let shift = options.shift(frame: frame, of: frameCount, width: w)
            warp(base, disparity: disparity, shiftX: shift.x, shiftY: shift.y,
                 into: &warped)
            while !input.isReadyForMoreMediaData {
                usleep(2000)
            }
            guard let pool = adaptor.pixelBufferPool else {
                throw StackError.io("animation writer lost its buffer pool")
            }
            var maybeBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &maybeBuffer)
            guard let buffer = maybeBuffer else { throw StackError.io("no pixel buffer") }
            try render(warped, into: buffer)
            let time = CMTime(value: CMTimeValue(Double(frame) / options.fps * 600),
                              timescale: timescale)
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw StackError.io("animation writer: \(writer.error?.localizedDescription ?? "append failed")")
            }
            progress?(Double(frame + 1) / Double(frameCount))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status != .completed {
            throw StackError.io("animation writer: \(writer.error?.localizedDescription ?? "did not complete")")
        }
        log?("wrote \(url.lastPathComponent)")
    }

    /// Animated GIF via ImageIO, flagged to loop forever (NETSCAPE loop
    /// count 0) — the auto-looping format: Quick Look, browsers, and
    /// message apps all replay it endlessly without being asked.
    private static func writeGIF(to url: URL, base: ImageBuffer, disparity: [Float],
                                 frameCount: Int, options: Options,
                                 progress: ((Double) -> Void)?,
                                 cancellation: CancellationToken?) throws {
        try? FileManager.default.removeItem(at: url)
        guard let dest = CGImageDestinationCreateWithURL(
                url as CFURL, "com.compuserve.gif" as CFString, frameCount, nil) else {
            throw StackError.io("couldn't create GIF at \(url.path)")
        }
        // Note: ImageIO stamps a "GIF87a" magic even though it writes the
        // 89a-only NETSCAPE loop and delay extensions — players don't care.
        CGImageDestinationSetProperties(dest, [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFLoopCount as String: 0,
            ],
        ] as CFDictionary)
        let delay = 1.0 / options.fps
        let frameProps = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFDelayTime as String: delay,
                kCGImagePropertyGIFUnclampedDelayTime as String: delay,
            ],
        ] as CFDictionary
        var warped = ImageBuffer(width: base.width, height: base.height)
        for frame in 0..<frameCount {
            try cancellation?.checkCancelled()
            let shift = options.shift(frame: frame, of: frameCount, width: base.width)
            warp(base, disparity: disparity, shiftX: shift.x, shiftY: shift.y,
                 into: &warped)
            guard let cg = try? ImageFile.cgImage8(from: warped) else {
                throw StackError.io("animation frame conversion failed")
            }
            CGImageDestinationAddImage(dest, cg, frameProps)
            progress?(Double(frame + 1) / Double(frameCount))
        }
        guard CGImageDestinationFinalize(dest) else {
            throw StackError.io("couldn't finish writing the GIF")
        }
    }

    /// Box-filter downsample of image and depth together (averaging depth
    /// across a box is fine: it only feeds sub-pixel disparities).
    static func downsample(_ image: ImageBuffer, depth: [Float],
                           to size: (w: Int, h: Int)) -> (ImageBuffer, [Float]) {
        let (w, h) = size
        guard w < image.width || h < image.height else { return (image, depth) }
        var out = ImageBuffer(width: w, height: h)
        var outDepth = [Float](repeating: 0, count: w * h)
        let sw = image.width, sh = image.height
        image.pixels.withUnsafeBufferPointer { src in
            depth.withUnsafeBufferPointer { srcD in
                out.pixels.withUnsafeMutableBufferPointer { dst in
                    outDepth.withUnsafeMutableBufferPointer { dstD in
                        DispatchQueue.concurrentPerform(iterations: h) { y in
                            let y0 = y * sh / h, y1 = max(y0 + 1, (y + 1) * sh / h)
                            for x in 0..<w {
                                let x0 = x * sw / w, x1 = max(x0 + 1, (x + 1) * sw / w)
                                var r: Float = 0, g: Float = 0, b: Float = 0, d: Float = 0
                                for sy in y0..<y1 {
                                    var si = (sy * sw + x0) * 4
                                    var sdi = sy * sw + x0
                                    for _ in x0..<x1 {
                                        r += src[si]; g += src[si + 1]; b += src[si + 2]
                                        d += srcD[sdi]
                                        si += 4; sdi += 1
                                    }
                                }
                                let n = Float((y1 - y0) * (x1 - x0))
                                let di = (y * w + x) * 4
                                dst[di] = r / n; dst[di + 1] = g / n; dst[di + 2] = b / n
                                dst[di + 3] = 1
                                dstD[y * w + x] = d / n
                            }
                        }
                    }
                }
            }
        }
        return (out, outDepth)
    }

    /// Depth plane → per-pixel disparity weights in [-0.5, 0.5], centered
    /// on the depth midrange with a robust (2nd/98th percentile) span so a
    /// few outlier pixels can't flatten the whole animation.
    static func normalizedDisparity(_ depth: [Float]) -> [Float] {
        var sorted = depth
        sorted.sort()
        let lo = sorted[Int(Double(sorted.count - 1) * 0.02)]
        let hi = sorted[Int(Double(sorted.count - 1) * 0.98)]
        let span = hi - lo
        guard span > 1e-3 else {
            return [Float](repeating: 0, count: depth.count)  // flat depth: no motion
        }
        return depth.map { min(max(($0 - lo) / span, 0), 1) - 0.5 }
    }

    /// Gather-warp: each destination pixel samples the base image at
    /// (x, y) + shift·disparity(x, y), bilinear, edge-clamped.
    static func warp(_ base: ImageBuffer, disparity: [Float],
                     shiftX: Float, shiftY: Float, into out: inout ImageBuffer) {
        let w = base.width, h = base.height
        base.pixels.withUnsafeBufferPointer { src in
            disparity.withUnsafeBufferPointer { disp in
                out.pixels.withUnsafeMutableBufferPointer { dst in
                    DispatchQueue.concurrentPerform(iterations: h) { y in
                        let row = y * w
                        for x in 0..<w {
                            let d = disp[row + x]
                            let sx = min(max(Float(x) + shiftX * d, 0), Float(w - 1))
                            let sy = min(max(Float(y) + shiftY * d, 0), Float(h - 1))
                            let x0 = Int(sx), y0 = Int(sy)
                            let x1 = min(x0 + 1, w - 1), y1 = min(y0 + 1, h - 1)
                            let fx = sx - Float(x0), fy = sy - Float(y0)
                            let a = (y0 * w + x0) * 4, b = (y0 * w + x1) * 4
                            let c = (y1 * w + x0) * 4, e = (y1 * w + x1) * 4
                            let di = (row + x) * 4
                            for ch in 0..<3 {
                                let top = src[a + ch] + (src[b + ch] - src[a + ch]) * fx
                                let bot = src[c + ch] + (src[e + ch] - src[c + ch]) * fx
                                dst[di + ch] = top + (bot - top) * fy
                            }
                            dst[di + 3] = 1
                        }
                    }
                }
            }
        }
    }

    /// Float working-space pixels → sRGB BGRA into the encoder's buffer
    /// (CoreGraphics does the color conversion while drawing).
    private static func render(_ image: ImageBuffer, into buffer: CVPixelBuffer) throws {
        guard let cg = try? ImageFile.cgImage8(from: image) else {
            throw StackError.io("animation frame conversion failed")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: base,
                                  width: image.width, height: image.height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                  space: srgb,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw StackError.io("animation frame context failed")
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return
    }
    #else
    /// Rocking export depends on AVFoundation (MP4) / ImageIO (GIF); on
    /// platforms without them it is not yet available (FFmpeg + giflib backend
    /// is a later port item). Kept as a throwing stub so the rest of the CLI
    /// builds and ships. Not on the synth-gate path.
    public static func write(to url: URL, image: ImageBuffer, depth: [Float],
                             options: Options = Options(),
                             log: ((String) -> Void)? = nil,
                             progress: ((Double) -> Void)? = nil,
                             cancellation: CancellationToken? = nil) throws {
        throw ImageFileError.unsupported(
            "rocking animation export is not available on this platform yet")
    }
    #endif
}
