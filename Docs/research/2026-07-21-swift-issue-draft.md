# swiftlang/swift issue — FILED 2026-07-21 as
# https://github.com/swiftlang/swift/issues/90874
# (this file is the draft it was filed from; the issue is the live copy)

**Title**: arm64 -O: ISel emits invalid SSA around ObjC error-bridged calls
in throwing functions ("PHI operand is not live-out from predecessor");
downstream symptoms include RegisterCoalescer/RAGreedy ICEs and a silent
swifterror miscompile (x21 non-zero on normal return)

## Headline reproduction (pristine project, one command)

```
git clone <hyperfocal repo> && cd hyperfocal   # commit b7c6673, unmodified
swift build -Xswiftc -Xllvm -Xswiftc -verify-machineinstrs
```

→ signal 6 during `hyperfocal-cli`:

```
*** Bad machine code: PHI operand is not live-out from predecessor ***
- function: $s14hyperfocal_cli4FuseV3runyyKF
- instruction: %4134:gpr64all = PHI %3946:gpr64all, %bb.280, %4111:gpr64all, %bb.316
*** Bad machine code: Virtual register defs don't dominate all uses. ***
```

The dump is flagged **"After Instruction Selection"** — the invalid SSA
comes straight out of ISel (swifterror PHI placement), before any
optimization pass runs. Flagged functions characteristically contain
ObjC error-bridged calls (`objc_msgSend$...error:`, NSError** bridging)
inside throwing Swift functions; isolating a single
`FileManager.createDirectory` call in a 5-line `@inline(never)` throwing
wrapper still gets the wrapper itself flagged. Normal builds (no
verifier) only work because downstream passes happen to tolerate the
invalid IR — see the symptoms below for what happens when they don't.

## Description

Compiling a large throwing static function (`GPUPyramid.fuse` in the
project below) at `-O` for arm64-apple-macosx crashes swift-frontend in
LLVM's Register Coalescer:

```
Running pass 'Register Coalescer' on function '@"$s13HyperfocalKit10GPUPyramidO4fuse..."'
(anonymous namespace)::JoinVals::computeAssignment(unsigned int, (anonymous namespace)::JoinVals&) + 1076
(anonymous namespace)::RegisterCoalescer::joinCopy(...)
EXC_BAD_ACCESS KERN_INVALID_ADDRESS at 0x0000000000000008
```

Reproduces on Apple Swift 6.2.3 (swiftlang-6.2.3.3.21, Xcode 26) and
Apple Swift 6.3.3 (swiftlang-6.3.3.1.3, Xcode 26.5), arm64 macOS 26.

Worse: in slightly different IR shapes of the same function (no
`@_optimize(none)` anywhere, but the buffer property of the pixel type
wrapped in a trivial struct), the coalescer does NOT crash and instead
appears to join wrong — the compiled throwing function returns from a
**normal** (non-throwing) path with the error register x21 holding a
stray data pointer. `swift_willThrow` never fires; the caller's
`cbz x21` then "catches" a phantom error and crashes in
`swift_errorRetain`/`objc_retain` retaining page-aligned zero-filled
pixel memory. Verified: the caller's error discipline is correct
(x21 zeroed before the call), the callee has a single `ret` whose
epilogue moves the saved error register out, and dynamic exclusivity
checking (`-enforce-exclusivity=checked` at -O) plus TSan both come
back clean — this is not source-level UB.

## Reproduction (ICE, one attribute on a pristine tree)

```
git clone <hyperfocal repo> && cd hyperfocal   # commit b7c6673
# add @_optimize(none) to GPUPyramid.fuse (Sources/HyperfocalKit/GPUPyramid.swift:20)
swift build          # Kit builds -O even in debug (Package.swift unsafeFlags)
# → swift-frontend SIGSEGV, Register Coalescer / JoinVals::computeAssignment
```

Crash logs: swift-frontend-2026-07-21-{155807,160236,170438,175946,180000,180218,180235}.ips
(both toolchains; happy to attach).

## Reproduction (runtime miscompile, no ICE)

Apply the PixelStorage refactor from
`Docs/research/2026-07-21-pixelstorage-toolchain-bug.md` (or just wrap
`ImageBuffer.pixels` in a trivial struct with identical API), build,
then:

```
.build/debug/hyperfocal-cli synth -o /tmp/synth
.build/debug/hyperfocal-cli fuse /tmp/synth/frame_*.tif -o /tmp/o.tif --method pmax --engine gpu
# → SIGSEGV: objc_retain of page-aligned zeroed memory "caught" as an error
#   in PyramidFusion.fuse, x21 == the phantom pointer at the catch
```

## Notes

- `@_optimize(none)` on the function makes the ICE fire even though the
  Register Coalescer would be expected to skip optnone functions —
  possibly related to `-enable-default-cmo`.
- The guilty-function set of the silent variant moves between 6.2.3 and
  6.3.3 (`@_optimize(none)` pairs that cured 6.2.3 don't cure 6.3.3),
  consistent with downstream passes consuming invalid IR whose damage
  depends on inlining decisions.
- With `-Xllvm -join-liveintervals=false` the ICE moves from
  RegisterCoalescer (`JoinVals::computeAssignment`, null deref 0x8) to
  RAGreedy (`SplitEditor::finish`) — both are consumers of the corrupt
  live intervals, not the source.
- Structural workarounds in user code (splitting the large functions,
  isolating ObjC calls, `@_optimize(none)` on victims) only relocate the
  failure; verified 2026-07-21.
