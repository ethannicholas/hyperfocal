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

## Update 2 (2026-07-21, later): UB ruled out — it's LLVM's Register Coalescer

The UB-hunting battery from "Path forward" ran on Swift 6.3.3 with the
refactor reapplied (same repro: probe SIGSEGV, `objc_retain` of a
page-aligned zero-filled pointer, caught live in lldb with
`breakpoint set -n swift_errorRetain -c '($x0 & 0x3fff) == 0 && $x0 != 0'`
— x21 = x0 = page-aligned, pointee all zeros). All three probes clean:

- **Exclusivity**: `swift build -Xswiftc -enforce-exclusivity=checked`
  (verified in debug.yaml; the Kit's debug `-O` keeps the repro hot) —
  no "Simultaneous accesses" trap, identical crash.
- **TSan**: `swift build --sanitize=thread` — probe runs to completion,
  `probe: ALL PASS`, zero ThreadSanitizer warnings (instrumentation
  perturbs codegen enough that the miscompile doesn't fire; a real race
  would still be flagged).
- **UncheckedSendable audit**: all three sites (ProjectStore.fixed16Data
  / readFixed16, RetouchSession.stamp + convert helpers) are
  structurally safe — disjoint rows, pointers scoped to the synchronous
  concurrentPerform call. The Kit itself has none; the pmax `frame`
  closure captures only value-typed StackSource state.

Static forensics on the crashing binary agree with a callee-side bug:
the specialized `PyramidFusion.fuse` caller is correct (saves incoming
x21, restores before the call, `cbz x21` after), and `GPUPyramid.fuse`
has exactly one `ret`, whose epilogue does `x21 := x19`, with every
visible write to x19 either the entry save, the post-call error save,
or a genuine `swift_allocError` throw path. The phantom enters through
a callee's normal return and is then propagated as if real.

**The smoking gun**: adding `@_optimize(none)` to `GPUPyramid.fuse`
makes swift-frontend itself SIGSEGV — `Running pass 'Register
Coalescer' on function '...GPUPyramidO4fuse...'`, crashing in
`(anonymous namespace)::JoinVals::computeAssignment` (null deref at
0x8, the live-range join logic). Five crash reports from 2026-07-21
alone, across BOTH toolchains (15:58/16:02 under 6.2.3 during the
original refactor session — unnoticed then; 17:04/17:59/18:00 under
6.3.3). And critically: the ICE fires on the PRISTINE tree too — bare
`[Float]`, no refactor, one attribute added at commit b7c6673.
So the shipped `GPUPyramid.fuse` already sits on the edge of a fragile
live-range join; IR-shape perturbations (the wrapper struct's ownership
lowering, or the attribute) tip it into either an outright ICE or a
silent wrong join that leaves a pixel-storage base pointer in the
swifterror register (x21) on a normal return — the phantom error. This
also explains the "guilty function set moves between compiler
versions": the trigger is the coalescer's view of one huge function,
not any specific source line.

Faster repro than the probe: the CLI crashes identically in seconds —
`hyperfocal-cli fuse <synth frames> -o out.tif --method pmax --engine
gpu`. `@_optimize(none)` on `FramePrefetcher.next()` alone does NOT
cure 6.3.3.

No matching issue found on swiftlang/swift (searched 2026-07-21).
**Verdict: compiler bug, not latent UB. File it** — the one-attribute
pristine-tree ICE is the actionable repro (Apple Swift 6.3.3,
swiftlang-6.3.3.1.3, Xcode 26.5, arm64 macOS 26): checkout b7c6673,
add `@_optimize(none)` to `GPUPyramid.fuse`, `swift build`. Attach the
runtime-miscompile story (this doc) as the impact statement.

Call-site fixes for reapplying the refactor (the "~10 sites", concretely):
`ImageBuffer.cropped` ×2 (replaceSubrange → memcpy under with*Pointer),
`Warp.applyLanczos3(into:)` (split: pointer-core + `[Float]`/PixelStorage
overloads — CPUWorkspace.gauss stays `[[Float]]`, WarpBench needs the
array shape), `DMapFusion.meanChannels` (same split),
`ProjectStore.fixed16Data` (same split), probe `maxDiskDiff` (PixelStorage
args) and `maxDiff` (index-loop overload; zip needs Sequence).

## Update 3 (2026-07-21, evening): workarounds exhausted — root cause is
## invalid SSA out of ISel, present in the PRISTINE tree

Every structural workaround was tried against the fast CLI repro
(`hyperfocal-cli fuse <synth> --method pmax --engine gpu`, crashes in
seconds) and failed:

- **Split `GPUPyramid.fuse`** into a state object with per-phase methods
  (setup/upload/encodeLevel/encodeFrame/drain/run): crash unchanged. An
  lldb x21 trace (symbol breakpoints + python auto-continue commands)
  showed x21 clean at every chain entry, dirty (alternating ping-pong
  upload-buffer base pointers) at the non-throwing `drain()` entries —
  legal scratch use — and finally dirty at `$defer()` after the last
  `collapse` call: the phantom escapes through one specific merge near
  the epilogue. Victim shape confirmed again: throwing function
  returning the wrapper-bearing ImageBuffer.
- **`@_optimize(none)` whack-a-mole**: optnone on `collapse` converts
  the SIGSEGV to a SIGTRAP *inside* collapse — its now-honest
  rethrows-boundary check catches a phantom coming back from
  `PixelStorage.withUnsafeMutableBufferPointer`. The victim just walks
  upstream; unshippable, as Update 1 predicted.
- **`@inline(__always)` on all PixelStorage accessors** (to dissolve
  boundaries the way stdlib Array's @inlinable accessors do): crash
  unchanged.
- **`-Xllvm -join-liveintervals=false`** (disable copy coalescing): the
  one-attribute ICE *moves* from RegisterCoalescer to the Greedy
  Register Allocator (`SplitEditor::finish`) — the live-interval data is
  corrupt before either consumer runs.
- **`-Xllvm -verify-machineinstrs`** finds the root cause: the machine
  verifier rejects the IR **immediately "After Instruction Selection"**
  — `*** Bad machine code: PHI operand is not live-out from predecessor
  ***` + `*** Virtual register defs don't dominate all uses ***` — i.e.
  swift-frontend's ISel (swifterror PHI placement) emits invalid SSA
  before any optimization pass touches it. The flagged functions all
  contain **ObjC error-bridged calls (NSError** out-params) inside
  throwing Swift functions**, and isolating one such call in a 5-line
  `@inline(never)` wrapper still gets the wrapper itself flagged — the
  bridging pattern per se is malformed on this toolchain.
- **Control: the PRISTINE tree fails verification too** (unmodified
  checkout of b7c6673, no refactor, no attributes: CLI `Fuse.run` is
  flagged). The shipping build works by downstream-pass tolerance of
  invalid IR, not by correctness. The refactor's wrapper struct merely
  shifts inlining until the tolerance breaks.
- Reshaping the CLI toward verifier-cleanliness (decomposing
  `Fuse.run`/`Batch.run`, replacing `clock.measure`, ObjC-call
  isolation) was tried and **reverted**: cleanliness is unachievable
  (see above) and insufficient — with Kit and the fuse path
  verifier-clean, the runtime phantom persisted, so a verifier-blind
  wrong-join variant exists as well.

**Conclusion: no viable local workaround.** The engine stays on
`[Float]`; the refactor stays reverted. The bug report is now maximally
strong — deterministic, pristine-tree, one command:

```
swift build -Xswiftc -Xllvm -Xswiftc -verify-machineinstrs
# → signal 6: "Bad machine code" out of ISel, hyperfocal-cli Fuse.run
```

(Apple Swift 6.3.3 / Xcode 26.5 / arm64 macOS 26; the runtime
phantom-error crash and both ICE variants are downstream symptoms.)

## Path forward

1. ~~Corner it with UB-hunting tooling~~ Done — clean; it's the toolchain.
2. ~~Try structural workarounds~~ Done (Update 3) — none hold.
3. File the Swift bug (draft: `2026-07-21-swift-issue-draft.md`) with
   the verifier repro as the headline; re-test the refactor on each new
   toolchain with the CLI pmax repro (seconds) before re-attempting.
4. The zero-copy upload itself remains gated on this refactor plus the
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
