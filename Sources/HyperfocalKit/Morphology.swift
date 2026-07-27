import Foundation
import Dispatch

/// Binary morphology and labeling on full-res planes, for the PMax debloom
/// membership (`PyramidFusion.openBackground`). Square structuring elements —
/// the membership is a coarse spatial classification, not geometry-critical,
/// and separable windowed OR/AND is O(n) via per-line prefix counts.
enum Morphology {

    /// Windowed OR: true where any input is true within the (2r+1)² window.
    static func dilate(_ mask: [Bool], width: Int, height: Int, radius r: Int) -> [Bool] {
        windowedAny(windowedAny(mask, width: width, height: height,
                                radius: r, alongRows: true),
                    width: width, height: height, radius: r, alongRows: false)
    }

    /// Windowed AND: true where every input is true within the (2r+1)² window.
    static func erode(_ mask: [Bool], width: Int, height: Int, radius r: Int) -> [Bool] {
        dilate(mask.map { !$0 }, width: width, height: height, radius: r).map { !$0 }
    }

    private static func windowedAny(_ mask: [Bool], width: Int, height: Int,
                                    radius r: Int, alongRows: Bool) -> [Bool] {
        var out = [Bool](repeating: false, count: mask.count)
        let lines = alongRows ? height : width
        let len = alongRows ? width : height
        let stride0 = alongRows ? 1 : width      // step within a line
        let stride1 = alongRows ? width : 1      // step between lines
        mask.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                DispatchQueue.concurrentPerform(iterations: lines) { line in
                    let base = line * stride1
                    // Prefix counts of trues along the line.
                    var prefix = [Int32](repeating: 0, count: len + 1)
                    for i in 0..<len {
                        prefix[i + 1] = prefix[i] + (src[base + i * stride0] ? 1 : 0)
                    }
                    for i in 0..<len {
                        let lo = max(i - r, 0), hi = min(i + r, len - 1)
                        dst[base + i * stride0] = prefix[hi + 1] - prefix[lo] > 0
                    }
                }
            }
        }
        return out
    }

    struct Components {
        /// 0 where `open` was false; 1-based component id elsewhere.
        var labels: [Int32]
        var count: Int
        var sizes: [Int]
        var touchesBorder: [Bool]
    }

    /// 4-connected components of the true region, iterative flood fill.
    /// Pixels are labeled when pushed, so each is visited exactly once.
    static func components(open: [Bool], width: Int, height: Int) -> Components {
        var labels = [Int32](repeating: 0, count: open.count)
        var sizes: [Int] = []
        var touches: [Bool] = []
        var stack: [Int32] = []
        var next: Int32 = 0
        open.withUnsafeBufferPointer { op in
            labels.withUnsafeMutableBufferPointer { lb in
                for seed in 0..<op.count where op[seed] && lb[seed] == 0 {
                    next += 1
                    var size = 0
                    var border = false
                    stack.removeAll(keepingCapacity: true)
                    stack.append(Int32(seed))
                    lb[seed] = next
                    while let idx32 = stack.popLast() {
                        let idx = Int(idx32)
                        let y = idx / width, x = idx % width
                        size += 1
                        if x == 0 || x == width - 1 || y == 0 || y == height - 1 {
                            border = true
                        }
                        if x > 0, op[idx - 1], lb[idx - 1] == 0 {
                            lb[idx - 1] = next; stack.append(Int32(idx - 1))
                        }
                        if x < width - 1, op[idx + 1], lb[idx + 1] == 0 {
                            lb[idx + 1] = next; stack.append(Int32(idx + 1))
                        }
                        if y > 0, op[idx - width], lb[idx - width] == 0 {
                            lb[idx - width] = next; stack.append(Int32(idx - width))
                        }
                        if y < height - 1, op[idx + width], lb[idx + width] == 0 {
                            lb[idx + width] = next; stack.append(Int32(idx + width))
                        }
                    }
                    sizes.append(size)
                    touches.append(border)
                }
            }
        }
        return Components(labels: labels, count: Int(next),
                          sizes: sizes, touchesBorder: touches)
    }
}
