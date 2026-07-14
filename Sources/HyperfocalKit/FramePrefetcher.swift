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
    /// 64 GB / 12-core → 8.
    static var defaultLookahead: Int {
        let info = ProcessInfo.processInfo
        let cores = max(2, info.activeProcessorCount - 2)
        let memoryFrames = max(2, Int(info.physicalMemory / (4 << 30)))
        return min(cores, memoryFrames, 8)
    }

    init(indices: [Int], lookahead: Int = FramePrefetcher.defaultLookahead,
         decode: @escaping (Int) throws -> ImageBuffer) {
        self.order = indices
        self.decode = decode
        opQueue.maxConcurrentOperationCount = lookahead
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
