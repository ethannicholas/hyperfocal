import Foundation

/// Decodes frames on background threads ahead of consumption, so ImageIO decode
/// overlaps with GPU/CPU processing of the current frame. Frames are enqueued
/// lazily as the consumer advances, so at most `lookahead` frames are decoding
/// or waiting in memory at once — RAW decode dominates fusion wall-clock on
/// big stacks, but a 45 MP float frame is ~0.7 GB, so the window must stay
/// bounded no matter how far decode outruns consumption.
final class FramePrefetcher {
    private let condition = NSCondition()
    private var results: [Int: Result<ImageBuffer, Error>] = [:]
    private let order: [Int]
    private var cursor = 0    // next frame to hand to the consumer
    private var enqueued = 0  // next frame to start decoding
    private let opQueue = OperationQueue()
    private let decode: (Int) throws -> ImageBuffer

    /// Decode workers sized to the hardware: leave a couple of cores for the
    /// consumer (GPU submission / CPU fusion), and cap the in-flight frames
    /// so the window fits in about a quarter of physical memory even for
    /// 45 MP frames (~1 GB each with decode transients). 16 GB / 8-core → 4;
    /// 64 GB / 12-core → 8. The floor is 1, not 2: a machine under 8 GiB
    /// (VMs report less than the nominal figure) genuinely cannot afford two
    /// in-flight 45 MP decode transients on top of a fusion's accumulators —
    /// measured pushing an 8 GB Linux box into the OOM killer when a
    /// secondary fusion re-decoded a stack the model was still retaining.
    static var defaultLookahead: Int {
        let info = ProcessInfo.processInfo
        let cores = max(2, info.activeProcessorCount - 2)
        let memoryFrames = max(1, Int(info.physicalMemory / (4 << 30)))
        return min(cores, memoryFrames, 8)
    }

    /// Decode-worker count for a stack, for callers whose decode closure is
    /// pure RAW/ImageIO (the GPU paths — they warp on device). nil means one
    /// worker per window slot, i.e. as much concurrency as `lookahead` (and
    /// therefore memory) allows.
    ///
    /// The RAW cap is an **Apple-only** fact, and mis-applying it off Apple
    /// cost more than it ever saved there. On Apple, RAW decode runs through
    /// the internally-parallel (GPU) RAW engine, where extra concurrency only
    /// contends — measured on 45 MP NEFs, 4 concurrent decodes run ~65%
    /// SLOWER per frame than serial (0.84 vs 0.48 s/frame) and 2-way ties
    /// serial. Off Apple the decoder is LibRaw: one CPU thread per call, no
    /// device involved, so a cap of 2 pins an 8-core machine at 2 cores and
    /// starves everything downstream of it. Measured on a 20-frame 45 MP
    /// stack (Ryzen 7 7800X3D, RTX 4080 SUPER, wgpu engine, spill on):
    /// 65.5 s at 2 workers vs 34.7 s with the window's worth — and with the
    /// cap in place the GPU engine beat the CPU engine by 2 s out of 121,
    /// because decode, not fusion, was the whole wall clock.
    ///
    /// TIFF/JPEG decode is CPU-bound and scales on every platform, so non-RAW
    /// stacks keep the full window's workers — as do the CPU fusion paths,
    /// whose closures include the core-scaling CPU Lanczos warp.
    ///
    /// Memory is bounded by `lookahead`, not here: `init` clamps workers to
    /// the window, and `defaultLookahead` already sizes that window to
    /// physical memory (one in-flight 45 MP frame per 4 GiB). An 8 GB machine
    /// resolves to a window of 2 and so decodes 2 at a time regardless of
    /// what this returns — saturating its cores is not on offer, and paging
    /// would cost more than the cores would win.
    static func workers(for urls: [URL]) -> Int? {
        #if canImport(ImageIO)
        guard let first = urls.first else { return nil }
        return ImageFile.isRAW(first) ? 2 : nil
        #else
        return nil
        #endif
    }

    /// `lookahead` bounds the in-flight window (memory); `workers` bounds
    /// decode concurrency (nil = one per window slot). Distinct knobs — see
    /// `workers(for:)` for why RAW stacks want fewer workers than slots.
    init(indices: [Int], lookahead: Int = FramePrefetcher.defaultLookahead,
         workers: Int? = nil,
         decode: @escaping (Int) throws -> ImageBuffer) {
        self.order = indices
        self.decode = decode
        // HYPERFOCAL_PREFETCH_WORKERS overrides for benchmarking/ablation
        // (same pattern as the HYPERFOCAL_GUIDED_* switches).
        let envWorkers = ProcessInfo.processInfo
            .environment["HYPERFOCAL_PREFETCH_WORKERS"].flatMap(Int.init)
        opQueue.maxConcurrentOperationCount = min(envWorkers ?? workers ?? lookahead,
                                                  lookahead)
        opQueue.qualityOfService = .userInitiated
        // Prime the window; next() tops it up as frames are consumed.
        for _ in 0..<min(lookahead, indices.count) { enqueueNext() }
    }

    /// Consumer thread only (init and next() call it) — `enqueued` needs no lock.
    private func enqueueNext() {
        guard enqueued < order.count else { return }
        let index = order[enqueued]
        enqueued += 1
        opQueue.addOperation { [weak self] in
            guard let self else { return }
            let result = Result { try self.decode(index) }
            self.condition.lock()
            self.results[index] = result
            self.condition.broadcast()
            self.condition.unlock()
        }
    }

    /// Blocks until the next frame (in the order given at init) is decoded.
    func next() throws -> (index: Int, image: ImageBuffer) {
        precondition(cursor < order.count, "prefetcher exhausted")
        let index = order[cursor]
        cursor += 1
        // Top up before blocking, so the decode window stays full while this
        // thread waits on a slow frame (momentarily lookahead + 1 in flight).
        enqueueNext()
        condition.lock()
        while results[index] == nil {
            condition.wait()
        }
        let result = results.removeValue(forKey: index)!
        condition.unlock()
        return (index, try result.get())
    }

    func cancel() {
        opQueue.cancelAllOperations()
    }
}
