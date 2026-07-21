# PixelStorage refactor: blocked by a Swift 6.2.3 arm64 -O miscompile class

## What was attempted (2026-07-21)

`ImageBuffer.pixels: [Float]` → `PixelStorage`, a CoW value type over
page-aligned, page-rounded raw storage, so Metal's
`makeBuffer(bytesNoCopy:)` can wrap frames zero-copy (a Swift Array can
never satisfy the contract: its elements sit 32 bytes past the storage
object's base — verified empirically at every size).

The refactor itself worked: whole tree compiled (Kit, CLI, AppCore,
probe, bridge, wgpu, app), warp bench flat at 8.2 ns/px, CPU and Metal
dmap outputs **bit-identical** to pre-refactor, parity 110.3 dB.

## Why it was reverted

The probe's pmax section crashes deterministically: `objc_retain` of a
page-aligned, zero-filled pointer (pixel memory) treated as a *thrown
error object*. Diagnosis (symbol-breakpoint forensics; address
breakpoints don't arm in this lldb environment — use symbol
breakpoints):

- `swift_willThrow` never fires: no Swift code ever throws.
- Throwing functions in the pmax path return from **normal** paths with
  the error register (x21) non-zero, holding a stray page-aligned
  pointer. Callers then "catch" a phantom error and crash retaining
  pixel memory.
- Confirmed in TWO distinct functions — `FramePrefetcher.next()`
  (trigger shape: `return (index, try result.get())` with the
  multi-word tuple payload) and `GPUPyramid.fuse` — each verified by
  `@_optimize(none)` bisection: full `-Onone` Kit is clean; either
  function alone at `-O` reintroduces the crash.
- ANY wrapper struct in `ImageBuffer.pixels` triggers it — including a
  trivial wrapper around the original `[Float]` with identical API. The
  aligned raw storage is irrelevant to the bug.

Because this is a *class* of miscompiles (throwing + wrapper-struct
ImageBuffer at -O), per-function `@_optimize(none)` whack-a-mole is not
shippable: the app and bridge paths have no probe coverage for every
such function.

## Reproduction (~3 minutes)

Apply the refactor (PixelStorage below + mechanical call-site fixes),
`swift build`, run `retouch-probe` on any synth stack: SIGSEGV in the
pmax section, `objc_retain` at fault address 0x20 (the zeroed "isa").
Even the trivial-wrapper variant reproduces. Toolchain:
Apple Swift 6.2.3 (swiftlang-6.2.3.3.21), Xcode 26, arm64 macOS 26.

## Update: Swift 6.3.3 (Xcode 26.5, same day) — NOT fixed, and worse

Retried on Swift 6.3.3 after the Xcode 26.5 upgrade (clean build):
identical phantom-error crash, including the trivial-wrapper variant.
Crucially, the two-function `@_optimize(none)` pair that cured 6.2.3
does NOT cure 6.3.3 — the guilty-function set moves between compiler
versions. Two readings, now genuinely uncertain:

- An optimizer bug family both compilers share (6.3 inherits 6.2's
  SIL optimizer lineage), whose inlining decisions shift per version; or
- Latent UB somewhere in the Kit (candidate class: the UncheckedSendable
  pointer-smuggling into concurrentPerform, or an exclusivity violation)
  that the wrapper's ABI/layout perturbation exposes — benign under the
  bare-[Float] layout both toolchains were tuned on.

## Path forward

1. Corner it with UB-hunting tooling rather than more workaround
   bisection: build the Kit with `-enforce-exclusivity=checked` at -O,
   run TSan on the probe, and audit the UncheckedSendable captures in
   the pmax path. If those come back clean, reduce to a standalone
   repro and file the Swift bug.
2. The zero-copy upload itself remains gated on this refactor plus the
   quiet-hardware measurement noted in ROADMAP.

## The preserved type

`PixelStorage` as last built (drop into `Sources/HyperfocalKit/`, then
fix call sites — the compiler finds all ~10; pattern notes in the
2026-07-21 session):

```swift
import Foundation

/// Page-aligned, page-rounded Float storage with `[Float]`-style value
/// semantics (copy-on-write). ImageBuffer's backing store.
///
/// Exists because a Swift `[Float]` can never satisfy Metal's
/// `makeBuffer(bytesNoCopy:)` contract: the elements live 32 bytes past the
/// storage object's base (measured at every size, 2026-07-21), so the base is
/// never page-aligned. This type allocates with page alignment AND rounds the
/// byte length to a page multiple, so unified-memory GPUs can wrap a frame's
/// pixels directly — no staging copy.
///
/// Concurrency: `@unchecked Sendable` under the CoW discipline — shared
/// values are never mutated (every mutation goes through `ensureUnique`),
/// which is exactly the guarantee `[Float]` gives.
public struct PixelStorage: @unchecked Sendable {

    /// One page on Apple Silicon; a stronger-than-needed alignment on
    /// 4 KB-page platforms, which costs nothing and keeps the layout
    /// contract identical everywhere.
    public static let pageSize = 16384

    final class Storage: @unchecked Sendable {
        let base: UnsafeMutableRawPointer
        let byteCapacity: Int  // page-rounded

        init(byteCapacity: Int) {
            self.byteCapacity = byteCapacity
            self.base = UnsafeMutableRawPointer.allocate(
                byteCount: byteCapacity, alignment: PixelStorage.pageSize)
        }

        deinit { base.deallocate() }
    }

    public let count: Int
    var storage: Storage

    var floats: UnsafeMutablePointer<Float> {
        storage.base.assumingMemoryBound(to: Float.self)
    }

    /// Zero-filled, like `[Float](repeating: 0, count:)`.
    public init(zeroed count: Int) {
        self.count = count
        let rounded = (count * 4 + Self.pageSize - 1) & ~(Self.pageSize - 1)
        self.storage = Storage(byteCapacity: max(rounded, Self.pageSize))
        memset(storage.base, 0, storage.byteCapacity)
    }

    /// Copies an existing array (decode paths and tests hand these in).
    public init(_ values: [Float]) {
        self.init(zeroed: values.count)
        values.withUnsafeBufferPointer {
            guard let b = $0.baseAddress else { return }
            memcpy(storage.base, b, values.count * 4)
        }
    }

    @inline(__always)
    mutating func ensureUnique() {
        if !isKnownUniquelyReferenced(&storage) {
            let fresh = Storage(byteCapacity: storage.byteCapacity)
            memcpy(fresh.base, storage.base, storage.byteCapacity)
            storage = fresh
        }
    }

    public var indices: Range<Int> { 0..<count }

    public subscript(_ i: Int) -> Float {
        get {
            assert(i >= 0 && i < count, "index \(i) out of range \(count)")
            return floats[i]
        }
        set {
            assert(i >= 0 && i < count, "index \(i) out of range \(count)")
            ensureUnique()
            floats[i] = newValue
        }
    }

    public func withUnsafeBufferPointer<R>(
        _ body: (UnsafeBufferPointer<Float>) throws -> R) rethrows -> R {
        try body(UnsafeBufferPointer(start: floats, count: count))
    }

    public mutating func withUnsafeMutableBufferPointer<R>(
        _ body: (inout UnsafeMutableBufferPointer<Float>) throws -> R) rethrows -> R {
        ensureUnique()
        var buf = UnsafeMutableBufferPointer(start: floats, count: count)
        return try body(&buf)
    }

    public func withUnsafeBytes<R>(
        _ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try body(UnsafeRawBufferPointer(start: storage.base, count: count * 4))
    }

    public mutating func withUnsafeMutableBytes<R>(
        _ body: (UnsafeMutableRawBufferPointer) throws -> R) rethrows -> R {
        ensureUnique()
        return try body(UnsafeMutableRawBufferPointer(start: storage.base, count: count * 4))
    }

    /// The page-aligned base and page-rounded length — exactly the
    /// `makeBuffer(bytesNoCopy:)` contract. Read-only use: the caller must
    /// not mutate through this, and the storage must outlive every use of
    /// the region (keep GPU encode → wait inside `body`).
    public func withPageAlignedRegion<R>(
        _ body: (UnsafeMutableRawPointer, Int) throws -> R) rethrows -> R {
        try body(storage.base, storage.byteCapacity)
    }

    /// A plain array copy, for consumers that genuinely need `[Float]`
    /// (serialization, tests).
    public func arrayCopy() -> [Float] {
        [Float](unsafeUninitializedCapacity: count) { buf, initialized in
            if let b = buf.baseAddress {
                memcpy(b, storage.base, count * 4)
            }
            initialized = count
        }
    }
}
```
