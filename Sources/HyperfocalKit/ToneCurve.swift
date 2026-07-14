import Foundation

/// Lightroom-style global tone adjustments (Exposure, Contrast, Highlights,
/// Shadows, Whites, Blacks). Neutral settings are exactly the identity.
///
/// These are *inspection/output* adjustments, not fusion parameters: the app
/// applies them to previews (so a fuse can be judged in deep shadow without a
/// round-trip through a raw developer) and bakes them into display-referred
/// exports (TIFF/PNG/JPEG). Linear DNG deliberately ignores them — that
/// format exists to hand unmodified linear data to a real raw developer.
public struct ToneSettings: Equatable, Codable, Sendable {
    /// Stops, ±5. Applied in linear light, so +2 EV genuinely quadruples
    /// energy rather than sliding gamma-encoded values.
    public var exposure: Double = 0
    /// The rest are Lightroom-range ±100 sliders.
    public var contrast: Double = 0
    public var highlights: Double = 0
    public var shadows: Double = 0
    public var whites: Double = 0
    public var blacks: Double = 0

    public init() {}

    public var isNeutral: Bool { self == ToneSettings() }
}

/// One curve definition feeding three consumers: the SwiftUI shader that
/// tones the preview panes, the Core Image color cube on the retouch canvas,
/// and the exact CPU application at export. All three sample `evaluate` (or a
/// LUT of it), so what the sliders show is what exports.
public enum ToneCurve {
    /// The curve on display-referred values in [0, 1], applied per channel.
    /// Exposure works in linear light; the shaping controls work on the
    /// re-encoded value with smooth region masks (shadows peak at 1/3,
    /// highlights at 2/3, blacks/whites at the ends), approximating how the
    /// Lightroom sliders divide the range.
    public static func evaluate(_ input: Float, settings s: ToneSettings) -> Float {
        var v = min(max(input, 0), 1)
        if s.exposure != 0 {
            v = srgbEncode(srgbLinearize(v) * exp2(Float(s.exposure)))
            v = min(max(v, 0), 1)
        }
        let c = Float(s.contrast) / 100
        if c > 0 {
            // Toward a smoothstep S-curve around the midpoint.
            v += c * (v * v * (3 - 2 * v) - v)
        } else if c < 0 {
            // Toward a flatter line through the midpoint.
            v += -c * 0.5 * (0.5 - v)
        }
        // Region masks: cubics peaking at 1 inside their range, zero at both
        // ends (so shadows/highlights never move pure black/white — that's
        // what blacks/whites are for).
        let h = Float(s.highlights) / 100
        if h != 0 { v += h * 0.3 * (v * v * (1 - v) * 6.75) }
        let sh = Float(s.shadows) / 100
        if sh != 0 { v += sh * 0.35 * (v * (1 - v) * (1 - v) * 6.75) }
        let w = Float(s.whites) / 100
        if w != 0 { v += w * 0.25 * v * v * v }
        let b = Float(s.blacks) / 100
        if b != 0 { v += b * 0.25 * (1 - v) * (1 - v) * (1 - v) }
        return min(max(v, 0), 1)
    }

    /// `evaluate` sampled uniformly over [0, 1].
    public static func lut(settings: ToneSettings, size: Int = 4096) -> [Float] {
        precondition(size >= 2)
        return (0..<size).map {
            evaluate(Float($0) / Float(size - 1), settings: settings)
        }
    }

    /// Applies the curve to RGB in place (alpha untouched), full precision —
    /// the export path. No-op for neutral settings.
    public static func apply(settings: ToneSettings, to image: inout ImageBuffer) {
        guard !settings.isNeutral else { return }
        let table = lut(settings: settings)
        let count = table.count
        let w = image.width
        image.pixels.withUnsafeMutableBufferPointer { px in
            table.withUnsafeBufferPointer { t in
                DispatchQueue.concurrentPerform(iterations: image.height) { y in
                    var i = y * w * 4
                    for _ in 0..<w {
                        for ch in 0..<3 {
                            let v = min(max(px[i + ch], 0), 1) * Float(count - 1)
                            let lo = Int(v)
                            let hi = min(lo + 1, count - 1)
                            let f = v - Float(lo)
                            px[i + ch] = t[lo] + (t[hi] - t[lo]) * f
                        }
                        i += 4
                    }
                }
            }
        }
    }

    /// Cube data for CIColorCubeWithColorSpace (RGBA float, dimension³
    /// entries). The curve is per-channel, so the cube is separable — exact
    /// up to the cube's own interpolation.
    public static func colorCubeData(settings: ToneSettings, dimension: Int = 64) -> Data {
        let table = lut(settings: settings, size: dimension)
        var cube = [Float](repeating: 1, count: dimension * dimension * dimension * 4)
        var i = 0
        for b in 0..<dimension {
            for g in 0..<dimension {
                for r in 0..<dimension {
                    cube[i] = table[r]
                    cube[i + 1] = table[g]
                    cube[i + 2] = table[b]
                    i += 4
                }
            }
        }
        return cube.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    // sRGB transfer (Display P3 shares it).
    static func srgbLinearize(_ v: Float) -> Float {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    static func srgbEncode(_ l: Float) -> Float {
        l <= 0.0031308 ? l * 12.92 : 1.055 * pow(l, 1 / 2.4) - 0.055
    }
}
