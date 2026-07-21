import Foundation
#if canImport(Vision)
import Vision
import CoreGraphics
#endif
#if canImport(simd)
import simd
#endif
#if !canImport(CoreGraphics)
import CImaging
#endif
#if HYPERFOCAL_HAVE_OPENCV
import COpenCVRegister  // macOS Phase 1.5 A/B: OpenCV registration alongside Vision
#endif

public enum AlignError: Error, CustomStringConvertible {
    case registrationFailed(Int)
    case tooFewGoodFrames(good: Int)

    public var description: String {
        switch self {
        case .registrationFailed(let i): return "registration failed for frame pair at index \(i)"
        case .tooFewGoodFrames(let good):
            return "too few usable frames after excluding bad ones (\(good) left; need 2)"
        }
    }
}

/// A frame the registration pass judged suspect: a flash misfire (exposure far
/// off the stack), a frame the registrar could not register, or one whose
/// post-warp residual says the registration didn't actually line it up (bumped
/// rail, subject moved). Indexes into the frame list that was registered.
public struct FrameQualityIssue: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Mean luminance vs the stack median, same encoded-space measurement
        /// the fusion's exposure-gain clamp uses; flagged outside [0.5, 2].
        case exposureOutlier(factor: Float)
        case registrationFailed
        /// Post-warp residual as a multiple of the stack's median pair residual.
        case misaligned(residualRatio: Float)
    }
    public let index: Int
    public let kind: Kind
    /// Human-readable reason, e.g. "4.1× darker than the stack".
    public let summary: String

    public init(index: Int, kind: Kind, summary: String) {
        self.index = index
        self.kind = kind
        self.summary = summary
    }
}

/// Which registration pass a progress callback reports: `decode` streams
/// the frames as shot; `register` works on gradient-magnitude images, so
/// its previews belong with derived output, not the source pane.
public enum RegistrationPass {
    case decode
    case register
}

/// The image a registration progress callback hands back for preview. It is the
/// grayscale representation the pass just touched — a `CGImage` where Apple's
/// imaging stack exists, the portable `GrayImage` otherwise.
#if canImport(CoreGraphics)
public typealias RegistrationPreview = CGImage
#else
public typealias RegistrationPreview = GrayImage
#endif

public enum Aligner {

    /// Full-length frame→reference transforms plus any quality flags raised
    /// along the way. Flagged frames get best-effort transforms (see
    /// `transformsAndQuality`); the chain itself only runs through good frames,
    /// so one bad frame can no longer corrupt the frames beyond it.
    public struct RegistrationOutput {
        public let transforms: [simd_float3x3]
        public let issues: [FrameQualityIssue]
    }

    /// Strict variant: throws if any frame failed to register (the historical
    /// behavior). Exposure/misalignment flags don't throw — those frames were
    /// always fused silently before detection existed.
    public static func transforms(forFrames urls: [URL],
                                  log: ((String) -> Void)? = nil,
                                  cancellation: CancellationToken? = nil,
                                  progress: ((_ fraction: Double, _ frameIndex: Int, _ frame: RegistrationPreview?, _ pass: RegistrationPass) -> Void)? = nil) throws -> [simd_float3x3] {
        let output = try transformsAndQuality(forFrames: urls, log: log,
                                              cancellation: cancellation, progress: progress)
        if let failure = output.issues.first(where: {
            if case .registrationFailed = $0.kind { return true } else { return false }
        }) {
            throw AlignError.registrationFailed(failure.index)
        }
        return output.transforms
    }

    /// Computes each frame's frame→reference transform by chaining adjacent-frame
    /// registrations (neighbors in a focus ramp share the most in-focus content, so
    /// pairwise registration is far more reliable than registering everything to one
    /// reference), while checking frame quality:
    ///
    /// - Exposure outliers (flash misfires): a frame whose mean luminance is more
    ///   than 2× off the stack median — the same bound the fusion's gain clamp
    ///   uses — is flagged and kept out of the chain.
    /// - Registration failures and misalignments: every registered pair is scored
    ///   by its post-warp residual (mean |difference| on quarter-resolution
    ///   grayscale). A frame whose *both* pairs are bad — or an end frame whose
    ///   only pair is — is the culprit and gets flagged; the chain re-registers
    ///   directly across the gap so downstream frames stay correct.
    ///
    /// Flagged frames still get best-effort transforms (registered as a spur off
    /// the nearest good frame when possible, else that neighbor's transform) so a
    /// caller that keeps them anyway has something sane. The reference (identity)
    /// frame is the middle *good* frame.
    ///
    /// Streams: only 8-bit grayscale frames are in memory, never float pixels.
    public static func transformsAndQuality(forFrames urls: [URL],
                                            log: ((String) -> Void)? = nil,
                                            cancellation: CancellationToken? = nil,
                                            progress: ((_ fraction: Double, _ frameIndex: Int, _ frame: RegistrationPreview?, _ pass: RegistrationPass) -> Void)? = nil) throws -> RegistrationOutput {
        let n = urls.count
        guard n > 1 else {
            return RegistrationOutput(transforms: [matrix_identity_float3x3], issues: [])
        }

        // Decode + register are the two units of work; report them as one span,
        // handing back the frame just touched so a UI can cycle its preview.
        // Bridge/spur registrations after exclusions aren't counted (few, and
        // the fraction clamps).
        let totalUnits = Double(n + n - 1)
        var completedUnits = 0
        let progressLock = NSLock()
        func bump(frameIndex: Int, frame: RegistrationPreview?, pass: RegistrationPass) {
            guard let progress else { return }
            progressLock.lock()
            completedUnits += 1
            let fraction = min(Double(completedUnits) / totalUnits, 1)
            progressLock.unlock()
            progress(fraction, frameIndex, frame, pass)
        }

        // Decode grayscale frames concurrently (bounded — decode dominates this
        // pass), then reduce each to its gradient-magnitude image: registration
        // and residuals both run on gradients, not luminance. In a deep stack's
        // tail the focus plane has left the subject but still cuts the surface
        // it sits on — faint sharp texture that raw-luminance registration
        // ignores while the big soft gradients of the defocused subject drag
        // the homography toward garbage. On gradient images the defocused
        // content nearly vanishes and the in-focus texture dominates. Only the
        // gradient plane stays in memory (~1/16th of the float image); the
        // luminance mean rides along for the exposure check.
        let decoded = try boundedConcurrentMap(count: n, concurrency: registrationConcurrency) { i -> (GrayImage, GrayStats, Float, RegistrationFrame) in
            try cancellation?.checkCancelled()
            let g = try ImageFile.loadGray8(url: urls[i])
            let (gradient, lumMean) = gradientImage(g)
            let stats = grayStats(gradient)
            // Per-frame registration prep (SIFT detection on the OpenCV
            // path) happens here, once — pairs only match.
            let regFrame = try prepareForRegistration(gradient)
            log?("decoded frame \(i)")
            bump(frameIndex: i, frame: preview(of: g), pass: .decode)
            return (gradient, stats, lumMean, regFrame)
        }
        let grays = decoded.map(\.0)
        let stats = decoded.map(\.1)
        let lumMeans = decoded.map(\.2)
        let regFrames = decoded.map(\.3)

        // Exposure outliers vs the stack *median* (robust: a near-black misfire
        // in a short stack would drag a mean-based reference toward itself).
        var issues = [FrameQualityIssue]()
        let medianMean = max(lumMeans.sorted()[n / 2], 0.25)
        var flagged = Set<Int>()
        for i in 0..<n {
            let factor = lumMeans[i] / medianMean
            if factor < 0.5 || factor > 2 {
                flagged.insert(i)
                let summary = factor < 1
                    ? String(format: "%.1f× darker than the stack", 1 / max(factor, 1e-3))
                    : String(format: "%.1f× brighter than the stack", factor)
                issues.append(FrameQualityIssue(
                    index: i, kind: .exposureOutlier(factor: factor), summary: summary))
            }
        }

        let kept = (0..<n).filter { !flagged.contains($0) }
        guard kept.count >= 2 else { throw AlignError.tooFewGoodFrames(good: kept.count) }

        // Register consecutive kept pairs concurrently; failures are data, not
        // errors (a bad frame shouldn't abort the whole fuse anymore).
        enum Pair {
            case ok(h: simd_float3x3, residual: Float)
            case failed
        }
        let pairs = try boundedConcurrentMap(count: kept.count - 1, concurrency: registrationConcurrency) { j -> Pair in
            try cancellation?.checkCancelled()
            let a = kept[j], b = kept[j + 1]
            defer { bump(frameIndex: b, frame: preview(of: grays[b]), pass: .register) }
            do {
                let h = try register(moving: regFrames[b], fixed: regFrames[a])
                let residual = pairResidual(fixed: stats[a], moving: stats[b], homography: h)
                // Occam gate: on featureless pairs (focus racked past every
                // surface — nothing but bokeh gradients) the registrar
                // confidently fits garbage homographies whose residuals still
                // look normal, and chaining a run of them bends the whole tail
                // of the stack (−46° rotations, 0.63× scales on a solid rail). A
                // warp that fits no better than not warping has not earned its
                // place in the chain; identity is the physical prior on a static
                // rail.
                let idResidual = pairResidual(fixed: stats[a], moving: stats[b],
                                              homography: matrix_identity_float3x3)
                // Clearly-worse only (garbage warps lose by 1.5–14×): a warp
                // that merely ties identity is usually a correct sub-pixel
                // registration whose improvement the quarter-res metric can't
                // resolve — substituting identity there breaks the chain at
                // that pair and misaligns everything downstream of it.
                if residual > idResidual * 1.02 {
                    log?("rejected warp \(b) → \(a) (residual \(String(format: "%.2f", residual)) vs identity \(String(format: "%.2f", idResidual)))")
                    return .ok(h: matrix_identity_float3x3, residual: idResidual)
                }
                log?("registered frame \(b) → \(a) (residual \(String(format: "%.2f", residual)))")
                return .ok(h: h, residual: residual)
            } catch {
                log?("registration FAILED for frame \(b) → \(a): \(error)")
                return .failed
            }
        }

        // Residual outliers: a registration that "succeeded" but didn't line the
        // frames up (bumped rail, wind) leaves a residual several times the
        // stack's typical pair difference (which is just defocus change + noise).
        let finiteResiduals = pairs.compactMap { p -> Float? in
            if case .ok(_, let r) = p, r.isFinite { return r } else { return nil }
        }
        guard !finiteResiduals.isEmpty else {
            throw AlignError.registrationFailed(kept[1])  // every pair failed
        }
        let medianResidual = max(finiteResiduals.sorted()[finiteResiduals.count / 2], 0.25)
        let poorThreshold = max(3 * medianResidual, 4.0)  // absolute floor: byte units
        func ratio(_ p: Pair) -> Float? {
            switch p {
            case .failed: return .infinity
            case .ok(_, let r):
                return r > poorThreshold ? r / medianResidual : nil
            }
        }
        let badPairs = pairs.indices.filter { ratio(pairs[$0]) != nil }

        // Blame: a bad frame poisons *both* its pairs; an end frame has only one.
        // First condemn frames with two bad pairs, then resolve remaining bad
        // pairs — endpoint frames are the culprit of their only pair; interior
        // *failed* pairs are tie-broken by test-registering across each endpoint;
        // interior poor-but-registered pairs with two otherwise-good endpoints
        // read as a scene change between frames, and only warn.
        var suspicion = [Int](repeating: 0, count: kept.count)
        for j in badPairs {
            suspicion[j] += 1
            suspicion[j + 1] += 1
        }
        var alignBad = Set<Int>()  // kept-list indices
        var bridgeCache = [Int: simd_float3x3]()  // key: lower kept-list index of the pair
        for ki in suspicion.indices where suspicion[ki] >= 2 { alignBad.insert(ki) }
        for j in badPairs {
            if alignBad.contains(j) || alignBad.contains(j + 1) { continue }
            if kept.count == 2 {
                // A 2-frame stack with its only pair bad: nothing to fall back on.
                if case .failed = pairs[j] { throw AlignError.registrationFailed(kept[1]) }
                log?("warning: high alignment residual between the only two frames")
                continue
            }
            if j == 0 {
                alignBad.insert(0)
            } else if j + 1 == kept.count - 1 {
                alignBad.insert(kept.count - 1)
            } else if case .failed = pairs[j] {
                // Interior failed pair, both endpoints otherwise fine: whichever
                // frame the chain can bridge around is the bad one.
                if let h = try? register(moving: regFrames[kept[j + 2]], fixed: regFrames[kept[j]]) {
                    alignBad.insert(j + 1)
                    bridgeCache[j] = h  // kept[j+2] → kept[j], keyed by lower survivor
                } else if let h = try? register(moving: regFrames[kept[j + 1]], fixed: regFrames[kept[j - 1]]) {
                    alignBad.insert(j)
                    bridgeCache[j - 1] = h
                } else {
                    throw AlignError.registrationFailed(kept[j + 1])
                }
            } else {
                log?("warning: high alignment residual between frames \(kept[j]) and \(kept[j + 1]) — possible scene change (not excluding either)")
            }
        }
        for ki in alignBad.sorted() {
            let adjacent = [ki > 0 ? ki - 1 : nil, ki < kept.count - 1 ? ki : nil]
                .compactMap { $0 }.filter { badPairs.contains($0) }
            let anyFailed = adjacent.contains { if case .failed = pairs[$0] { return true } else { return false } }
            let worst = adjacent.compactMap { ratio(pairs[$0]) }.filter(\.isFinite).max()
            let kind: FrameQualityIssue.Kind = anyFailed && worst == nil
                ? .registrationFailed
                : .misaligned(residualRatio: worst ?? .infinity)
            let summary = anyFailed && worst == nil
                ? "alignment failed"
                : String(format: "misaligned (%.1f× the stack's typical frame difference)", worst ?? 0)
            issues.append(FrameQualityIssue(index: kept[ki], kind: kind, summary: summary))
            flagged.insert(kept[ki])
        }
        issues.sort { $0.index < $1.index }

        // The surviving chain. Pair transforms between consecutive survivors:
        // reuse the round-1 registration when it exists (kept even if its
        // residual was poor — for surviving frames it's still the best estimate),
        // else the bridge from blame resolution, else register the gap fresh.
        let survivors = kept.indices.filter { !alignBad.contains($0) }.map { kept[$0] }
        guard survivors.count >= 2 else { throw AlignError.tooFewGoodFrames(good: survivors.count) }
        var chain = [matrix_identity_float3x3]
        for s in 0..<(survivors.count - 1) {
            let a = survivors[s], b = survivors[s + 1]
            let ja = kept.firstIndex(of: a)!, jb = kept.firstIndex(of: b)!
            let h: simd_float3x3
            if jb == ja + 1, case .ok(let m, _) = pairs[ja] {
                h = m
            } else if let bridged = bridgeCache[ja] {
                h = bridged
            } else {
                do {
                    h = try register(moving: regFrames[b], fixed: regFrames[a])
                    log?("bridged frame \(b) → \(a) across excluded frame(s)")
                } catch {
                    throw AlignError.registrationFailed(b)
                }
            }
            chain.append(chain[s] * h)
        }
        let refInverse = chain[survivors.count / 2].inverse
        var transforms = [simd_float3x3](repeating: matrix_identity_float3x3, count: n)
        for (s, frame) in survivors.enumerated() {
            transforms[frame] = refInverse * chain[s]
        }

        // Best-effort transforms for flagged frames, in case the caller keeps
        // them anyway: a spur registration onto the nearest survivor when the
        // registrar can manage one, else that survivor's transform verbatim.
        for f in flagged.sorted() {
            let nearest = survivors.min { abs($0 - f) < abs($1 - f) }!
            if let h = try? register(moving: regFrames[f], fixed: regFrames[nearest]) {
                transforms[f] = transforms[nearest] * h
            } else {
                transforms[f] = transforms[nearest]
            }
        }

        return RegistrationOutput(transforms: transforms, issues: issues)
    }

    // MARK: - Frame quality measurement

    /// Mean luminance plus a quarter-resolution byte plane for residual checks.
    /// Byte units throughout (0–255).
    struct GrayStats {
        let mean: Float
        let plane: [UInt8]
        let width: Int
        let height: Int
        /// Full-resolution pixels per plane pixel.
        let factor: Int
    }

    /// Sobel gradient magnitude of a grayscale frame as an 8-bit image,
    /// normalized so the frame's 99th-percentile magnitude maps to 255 —
    /// per-frame normalization keeps faintly-textured frames (deep-stack
    /// tails focused only on the substrate) comparable to sharp ones.
    /// Returns the source's luminance mean too (the exposure check needs it;
    /// gradient means are meaningless for that). Pure — identical on every
    /// platform; only decode/downscale/register touch the OS imaging stack.
    static func gradientImage(_ img: GrayImage) -> (image: GrayImage, lumMean: Float) {
        let w = img.width, h = img.height
        let lum = img.pixels
        var lumSum = 0
        for v in lum { lumSum += Int(v) }
        let lumMean = Float(lumSum) / Float(max(w * h, 1))

        // Sobel magnitude (|gx| + |gy| — the cheap L1 form), UInt16 range.
        var mag = [UInt16](repeating: 0, count: w * h)
        lum.withUnsafeBufferPointer { src in
            mag.withUnsafeMutableBufferPointer { dst in
                DispatchQueue.concurrentPerform(iterations: max(h - 2, 0)) { row in
                    let y = row + 1
                    for x in 1..<(w - 1) {
                        let i = y * w + x
                        let gx = Int(src[i - w + 1]) + 2 * Int(src[i + 1]) + Int(src[i + w + 1])
                               - Int(src[i - w - 1]) - 2 * Int(src[i - 1]) - Int(src[i + w - 1])
                        let gy = Int(src[i + w - 1]) + 2 * Int(src[i + w]) + Int(src[i + w + 1])
                               - Int(src[i - w - 1]) - 2 * Int(src[i - w]) - Int(src[i - w + 1])
                        dst[i] = UInt16(min(abs(gx) + abs(gy), 4080))
                    }
                }
            }
        }

        // p99 via histogram; normalize so p99 → 255.
        var histogram = [Int](repeating: 0, count: 4081)
        for v in mag { histogram[Int(v)] += 1 }
        var remaining = w * h / 100
        var p99 = 4080
        while p99 > 1 {
            remaining -= histogram[p99]
            if remaining <= 0 { break }
            p99 -= 1
        }
        let scale = 255.0 / Float(max(p99, 8))  // floor: don't amplify pure noise
        var bytes = [UInt8](repeating: 0, count: w * h)
        bytes.withUnsafeMutableBufferPointer { dst in
            mag.withUnsafeBufferPointer { src in
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    for i in (y * w)..<((y + 1) * w) {
                        dst[i] = UInt8(min(Float(src[i]) * scale, 255))
                    }
                }
            }
        }
        return (GrayImage(width: w, height: h, pixels: bytes), lumMean)
    }

    /// Mean |difference| between `fixed` and `moving` warped by `homography`
    /// (full-resolution coordinates, moving → fixed), sampled on the
    /// quarter-res planes. Adjacent focus-ramp frames differ only by defocus
    /// change and noise, so a well-registered pair scores a few byte units; a
    /// mis-registered or non-rigidly displaced frame scores several times that.
    static func pairResidual(fixed: GrayStats, moving: GrayStats,
                             homography: simd_float3x3) -> Float {
        let inv = homography.inverse
        let f = Float(fixed.factor)
        // ~150k samples regardless of resolution.
        let step = max(1, Int((Float(fixed.width * fixed.height) / 150_000).squareRoot().rounded()))
        var sum: Float = 0
        var count = 0
        var y = 0
        while y < fixed.height {
            var x = 0
            while x < fixed.width {
                let full = SIMD3<Float>((Float(x) + 0.5) * f, (Float(y) + 0.5) * f, 1)
                let p = inv * full
                let bx = p.x / p.z / f - 0.5
                let by = p.y / p.z / f - 0.5
                if bx >= 0, by >= 0, bx < Float(moving.width - 1), by < Float(moving.height - 1) {
                    let x0 = Int(bx), y0 = Int(by)
                    let tx = bx - Float(x0), ty = by - Float(y0)
                    let i00 = Float(moving.plane[y0 * moving.width + x0])
                    let i10 = Float(moving.plane[y0 * moving.width + x0 + 1])
                    let i01 = Float(moving.plane[(y0 + 1) * moving.width + x0])
                    let i11 = Float(moving.plane[(y0 + 1) * moving.width + x0 + 1])
                    let m = (i00 * (1 - tx) + i10 * tx) * (1 - ty)
                          + (i01 * (1 - tx) + i11 * tx) * ty
                    sum += abs(Float(fixed.plane[y * fixed.width + x]) - m)
                    count += 1
                }
                x += step
            }
            y += step
        }
        // Almost no overlap ⇒ the homography flung the frame off the canvas.
        guard count > 100 else { return .infinity }
        return sum / Float(count)
    }

    /// Runs `body` for each index with bounded concurrency, collecting results in
    /// order. Rethrows the first error encountered.
    /// Decode/register worker count: the historical 4, but never more than
    /// cores − 1 — on a 2-core VM, 4 concurrent SIFT registrations (each with
    /// OpenCV's own internal parallelism) starved the UI and the rest of the
    /// system for the whole pass.
    static var registrationConcurrency: Int {
        min(4, max(1, ProcessInfo.processInfo.activeProcessorCount - 1))
    }

    static func boundedConcurrentMap<T>(count: Int, concurrency: Int,
                                        _ body: @escaping (Int) throws -> T) throws -> [T] {
        var results = [T?](repeating: nil, count: count)
        var firstError: Error? = nil
        let lock = NSLock()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = concurrency
        queue.qualityOfService = .userInitiated
        for i in 0..<count {
            queue.addOperation {
                do {
                    let value = try body(i)
                    lock.lock()
                    results[i] = value
                    lock.unlock()
                } catch {
                    lock.lock()
                    if firstError == nil { firstError = error }
                    lock.unlock()
                }
            }
        }
        queue.waitUntilAllOperationsAreFinished()
        if let firstError { throw firstError }
        return results.map { $0! }
    }

    // MARK: - Platform primitives (decode-adjacent: downscale, register, preview)

    /// Longest side (px) SIFT registration runs at. Full-res SIFT on a 45 MP
    /// frame needs many GB and often finds no robust model; registering on a
    /// downscaled copy and mapping the homography back is the "downscale-for-
    /// registration" bound (validated on macOS via the Phase 1.5 A/B; applied
    /// on every OpenCV path). Synth frames (≤900 px) sit below this, so the
    /// synth gates are unaffected.
    /// SIFT input bound. 1200 (from 2500 via 1600, 2026-07-20): detect is
    /// the registration wall-clock wall and scales with area. Measured at
    /// each step on the 82 × 11 MP sample stack + a 3600×2400 jittered
    /// ground-truth synth: pair residuals flat, ratio-test matches high,
    /// zero rejects/flags, truth PSNR 50.26 dB at 1200 (50.29 at 1600,
    /// 49.62 at 2500) — and 1000 also passed (50.17), so 1200 is landed
    /// with a tested step of margin below it.
    /// 45 MP re-verify (2026-07-20, macOS A/B, 60-frame Fluorite NEF
    /// stack): the **1600** bound + 2000 cap passed quality-neutral vs
    /// the 2500/uncapped baseline — crop sizes within a few px,
    /// new↔Vision 33.3 dB vs baseline↔Vision 34.1 dB (cross-transform
    /// comparisons bottom out near there), 8× amplified diff black in the
    /// background with only texture-grain resampling differences, and 1:1
    /// silhouette crops indistinguishable. **1200 FAILED that bar at
    /// 45 MP** (same day, same stack, bound isolated on one binary via
    /// the env override): 1600↔1200 only 30.4 dB — ~3.5 dB beyond the
    /// same-family noise floor — the common-coverage crop grew ~10 px
    /// (under-estimated motion), and the amplified diff shows
    /// edge-following seams plus shifted background bokeh (misalignment
    /// signatures, not resampling grain). Hence the scale floor below:
    /// the bound is 1200 up to a 5× downscale, then grows with the
    /// frame (45 MP → 1651, at/above the validated 1600 scale) — 11 MP
    /// and smaller stacks keep 1200's measured detect cost exactly.
    /// The floor re-validated on the same stack: fix↔1600 35.2 dB (the
    /// tightest same-family agreement measured), fix↔Vision 31.8 dB.
    /// HYPERFOCAL_REGISTER_MAXSIDE overrides for ablation (same pattern as
    /// the HYPERFOCAL_SIFT_* switches).
    static func openCVRegisterMaxSide(longest: Int) -> Int {
        if let override = ProcessInfo.processInfo
            .environment["HYPERFOCAL_REGISTER_MAXSIDE"].flatMap(Int.init) {
            return override
        }
        return max(1200, longest / 5)
    }

    /// Area-average downscale of an 8-bit gray plane by `scale` (0<scale<1) —
    /// enough to feed SIFT; not the fusion sampler.
    static func boxDownscale(_ img: GrayImage, scale: Float) -> GrayImage {
        let w = img.width, h = img.height
        let pw = max(1, Int((Float(w) * scale).rounded())), ph = max(1, Int((Float(h) * scale).rounded()))
        var bytes = [UInt8](repeating: 0, count: pw * ph)
        img.pixels.withUnsafeBufferPointer { src in
            bytes.withUnsafeMutableBufferPointer { dst in
                DispatchQueue.concurrentPerform(iterations: ph) { y in
                    let y0 = y * h / ph, y1 = max(y0 + 1, (y + 1) * h / ph)
                    for x in 0..<pw {
                        let x0 = x * w / pw, x1 = max(x0 + 1, (x + 1) * w / pw)
                        var acc = 0, cnt = 0
                        for yy in y0..<min(y1, h) {
                            for xx in x0..<min(x1, w) { acc += Int(src[yy * w + xx]); cnt += 1 }
                        }
                        dst[y * pw + x] = UInt8(acc / max(cnt, 1))
                    }
                }
            }
        }
        return GrayImage(width: pw, height: ph, pixels: bytes)
    }

    /// H was fit in downscaled coords (p_small = s·p_full). Map back to
    /// full-res: H_full = S⁻¹ · H_small · S, with S = diag(s, s, 1).
    static func upscaleHomography(_ hs: simd_float3x3, scale s: Float) -> simd_float3x3 {
        let S = simd_float3x3(rows: [
            SIMD3<Float>(s, 0, 0), SIMD3<Float>(0, s, 0), SIMD3<Float>(0, 0, 1)])
        let sInv = simd_float3x3(rows: [
            SIMD3<Float>(1 / s, 0, 0), SIMD3<Float>(0, 1 / s, 0), SIMD3<Float>(0, 0, 1)])
        return sInv * hs * S
    }

#if canImport(Vision)

    /// Registers `moving` onto `fixed` and returns a homography mapping
    /// moving-image pixel coordinates (top-left origin, y down) to fixed-image
    /// pixel coordinates. Vision reports the warp in bottom-left pixel space,
    /// so `convention` conjugates by a vertical flip.
    public static func register(moving: CGImage, fixed: CGImage) throws -> simd_float3x3 {
        let request = VNHomographicImageRegistrationRequest(targetedCGImage: moving)
        let handler = VNImageRequestHandler(cgImage: fixed, options: [:])
        try handler.perform([request])
        guard let obs = request.results?.first else {
            throw AlignError.registrationFailed(0)
        }
        return convention(obs.warpTransform, height: Float(fixed.height))
    }

    static func register(moving: GrayImage, fixed: GrayImage) throws -> simd_float3x3 {
#if HYPERFOCAL_HAVE_OPENCV
        // Phase 1.5 A/B: HYPERFOCAL_REGISTER=opencv routes the macOS fusion
        // pipeline through the OpenCV backend instead of Vision, so both can be
        // measured on identical frames (synth PSNR + the fluorite stack). Vision
        // stays the default; this branch is compiled only when OpenCV is present.
        if useOpenCVRegistration {
            return try registerOpenCV(moving: moving, fixed: fixed)
        }
#endif
        return try register(moving: cgImage(from: moving), fixed: cgImage(from: fixed))
    }

#if HYPERFOCAL_HAVE_OPENCV
    /// Set once from the environment: the A/B is a whole-run choice, not per-pair.
    static let useOpenCVRegistration: Bool =
        ProcessInfo.processInfo.environment["HYPERFOCAL_REGISTER"]?.lowercased() == "opencv"

    /// OpenCV SIFT + RANSAC homography on the portable gray planes — the Linux
    /// backend (`register(GrayImage,GrayImage)` under `#else`) plus the residual-#3
    /// downscale bound. OpenCV is already top-left / y-down, so no Vision-style
    /// vertical-flip conjugation.
    static func registerOpenCV(moving: GrayImage, fixed: GrayImage) throws -> simd_float3x3 {
        precondition(moving.width == fixed.width && moving.height == fixed.height,
                     "OpenCV registration expects same-sized gray frames")
        let longest = max(moving.width, moving.height)
        let maxSide = openCVRegisterMaxSide(longest: longest)
        let scale: Float = longest > maxSide
            ? Float(maxSide) / Float(longest) : 1
        let sm = scale < 1 ? boxDownscale(moving, scale: scale) : moving
        let sf = scale < 1 ? boxDownscale(fixed, scale: scale) : fixed

        var h = [Float](repeating: 0, count: 9)
        let status = sf.pixels.withUnsafeBufferPointer { f in
            sm.pixels.withUnsafeBufferPointer { m in
                hfr_register(CInt(sf.width), CInt(sf.height),
                             f.baseAddress, m.baseAddress, &h)
            }
        }
        guard status == hfr_ok else { throw AlignError.registrationFailed(0) }
        let hs = simd_float3x3(rows: [
            SIMD3<Float>(h[0], h[1], h[2]),
            SIMD3<Float>(h[3], h[4], h[5]),
            SIMD3<Float>(h[6], h[7], h[8]),
        ])
        guard scale < 1 else { return hs }
        return upscaleHomography(hs, scale: scale)
    }
#endif

    /// Vision reports the warp in a bottom-left-origin pixel coordinate system.
    /// Conjugate by a vertical flip to get our top-left convention.
    static func convention(_ m: matrix_float3x3, height: Float) -> simd_float3x3 {
        let f = simd_float3x3(rows: [
            SIMD3<Float>(1, 0, 0),
            SIMD3<Float>(0, -1, height),
            SIMD3<Float>(0, 0, 1),
        ])
        return f * m * f
    }

    /// 8-bit gray `CGImage` wrapping a `GrayImage`'s bytes (no copy of intent —
    /// same space and layout the CoreGraphics gray path always used).
    static func cgImage(from g: GrayImage) -> CGImage {
        let w = g.width, h = g.height
        let space = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!
        let provider = CGDataProvider(data: Data(g.pixels) as CFData)!
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: w, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)!
    }

    static func preview(of g: GrayImage) -> RegistrationPreview { cgImage(from: g) }

    /// Vision registers gray images directly — no per-frame preparation to
    /// cache, so the "prepared frame" is the gradient image itself (the
    /// OpenCV branch detects SIFT here instead; see its RegistrationFrame).
    typealias RegistrationFrame = GrayImage
    static func prepareForRegistration(_ gradient: GrayImage) throws -> RegistrationFrame {
        gradient
    }

    static func grayStats(_ img: GrayImage, factor: Int = 4) -> GrayStats {
        let cg = cgImage(from: img)
        let pw = max(1, cg.width / factor), ph = max(1, cg.height / factor)
        var bytes = [UInt8](repeating: 0, count: pw * ph)
        bytes.withUnsafeMutableBytes { buf in
            guard let space = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2),
                  let ctx = CGContext(data: buf.baseAddress, width: pw, height: ph,
                                      bitsPerComponent: 8, bytesPerRow: pw,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: pw, height: ph))
        }
        var sum = 0
        for b in bytes { sum += Int(b) }
        return GrayStats(mean: Float(sum) / Float(max(bytes.count, 1)),
                         plane: bytes, width: pw, height: ph, factor: factor)
    }

#else  // Linux/Windows — OpenCV registration + a plain box downscale.

    static func preview(of g: GrayImage) -> RegistrationPreview { g }

    /// One frame's SIFT keypoints + descriptors, detected once on the
    /// registration-bounded downscale of its gradient image. Detection
    /// dominates pair cost and every interior frame sits in two pairs, so
    /// `transformsAndQuality` prepares each frame once (in the decode pass)
    /// and pairs match handles.
    final class RegistrationFrame {
        let handle: OpaquePointer
        let scale: Float          // downscale applied before detection
        let width: Int, height: Int   // original (gradient) dimensions

        init(gray: GrayImage) throws {
            // Bound SIFT's input (openCVRegisterMaxSide) and map the
            // homography back — same downscale-for-registration wrapper the
            // macOS A/B path validated; full-res SIFT on 45 MP frames needs
            // ~7.5 GB and often finds no model.
            let longest = max(gray.width, gray.height)
            let maxSide = openCVRegisterMaxSide(longest: longest)
            scale = longest > maxSide
                ? Float(maxSide) / Float(longest) : 1
            let small = scale < 1 ? boxDownscale(gray, scale: scale) : gray
            let h = small.pixels.withUnsafeBufferPointer {
                hf_sift_detect(CInt(small.width), CInt(small.height), $0.baseAddress)
            }
            guard let h else { throw AlignError.registrationFailed(0) }
            handle = h
            width = gray.width
            height = gray.height
        }

        deinit { hf_sift_free(handle) }
    }

    static func prepareForRegistration(_ gradient: GrayImage) throws -> RegistrationFrame {
        try RegistrationFrame(gray: gradient)
    }

    static func register(moving: RegistrationFrame, fixed: RegistrationFrame) throws -> simd_float3x3 {
        precondition(moving.width == fixed.width && moving.height == fixed.height,
                     "OpenCV registration expects same-sized gray frames")
        var h = [Float](repeating: 0, count: 9)
        guard hf_sift_match(fixed.handle, moving.handle, &h) == hf_ok else {
            throw AlignError.registrationFailed(0)
        }
        // OpenCV already works top-left / y-down, matching our convention — no
        // flip (unlike Vision's bottom-left warp).
        let hs = simd_float3x3(rows: [
            SIMD3<Float>(h[0], h[1], h[2]),
            SIMD3<Float>(h[3], h[4], h[5]),
            SIMD3<Float>(h[6], h[7], h[8]),
        ])
        guard moving.scale < 1 else { return hs }
        return upscaleHomography(hs, scale: moving.scale)
    }

    static func grayStats(_ img: GrayImage, factor: Int = 4) -> GrayStats {
        let w = img.width, h = img.height
        let pw = max(1, w / factor), ph = max(1, h / factor)
        var bytes = [UInt8](repeating: 0, count: pw * ph)
        img.pixels.withUnsafeBufferPointer { src in
            bytes.withUnsafeMutableBufferPointer { dst in
                DispatchQueue.concurrentPerform(iterations: ph) { y in
                    let y0 = y * h / ph, y1 = max(y0 + 1, (y + 1) * h / ph)
                    for x in 0..<pw {
                        let x0 = x * w / pw, x1 = max(x0 + 1, (x + 1) * w / pw)
                        var acc = 0, cnt = 0
                        var yy = y0
                        while yy < y1 && yy < h {
                            var xx = x0
                            while xx < x1 && xx < w {
                                acc += Int(src[yy * w + xx]); cnt += 1; xx += 1
                            }
                            yy += 1
                        }
                        dst[y * pw + x] = UInt8(acc / max(cnt, 1))
                    }
                }
            }
        }
        var sum = 0
        for b in bytes { sum += Int(b) }
        return GrayStats(mean: Float(sum) / Float(max(bytes.count, 1)),
                         plane: bytes, width: pw, height: ph, factor: factor)
    }

#endif
}
