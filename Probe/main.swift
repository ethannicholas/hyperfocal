import AppKit
import HyperfocalKit
import simd

// Headless integration tests for the app layer: retouch session loading,
// session serialization round-trip, and model-level project save/restore.
// 0. Guided depth regularizer on synthetic ramps: a flat guide must turn a
// confidence gap into a smooth ramp between the confident depths; a step
// guide must hold the depth transition to the guide edge.
do {
    let width = 256, height = 64, factor = 8, frames = 15
    let count = width * height
    var confidence = [Float](repeating: 0, count: count)
    var depth = [Float](repeating: 0, count: count)
    for y in 0..<height {
        for x in 0..<width {
            let i = y * width + x
            if x < 64 { confidence[i] = 1; depth[i] = 2 }
            else if x >= 192 { confidence[i] = 1; depth[i] = 12 }
        }
    }
    let opts = DMapFusion.Options()
    func runGuided(guide: [Float]) -> [Float] {
        guard let coeff = DepthRegularize.gridCoefficients(
                confidence: confidence, depthMed: depth, guide: guide,
                width: width, height: height, planes: [], factor: factor,
                frameCount: frames, options: opts) else {
            print("probe: GUIDED COEFFICIENTS NIL"); exit(1)
        }
        return DepthRegularize.applyBlend(coefficients: coeff, guide: guide,
                                          confidence: confidence, depthMed: depth,
                                          width: width, height: height,
                                          frameCount: frames)
    }

    let mid = height / 2
    let ramp = runGuided(guide: [Float](repeating: 0.5, count: count))
    // Confident plateaus keep their argmax exactly; the gap interior must be
    // a smooth monotone ramp between them. Where the guide is flat the ramp
    // meets the plateaus with a bounded step (seed-side bias — at real
    // silhouettes the guide edge carries continuity instead; bound it so a
    // regression can't grow it silently).
    var maxJump: Float = 0
    var maxDecrease: Float = 0
    for x in 66...190 {
        let d = ramp[mid * width + x] - ramp[mid * width + x - 1]
        maxJump = max(maxJump, abs(d))
        maxDecrease = max(maxDecrease, -d)
    }
    let center = ramp[mid * width + 128]
    let leftBias = abs(ramp[mid * width + 65] - 2)
    let rightBias = abs(ramp[mid * width + 190] - 12)
    guard abs(ramp[mid * width + 32] - 2) < 0.01, abs(ramp[mid * width + 224] - 12) < 0.01,
          maxJump < 0.5, maxDecrease < 0.05, center > 5, center < 9,
          leftBias < 4, rightBias < 4 else {
        print("probe: GUIDED FLAT-GUIDE RAMP WRONG (plateaus \(ramp[mid * width + 32]) "
              + "\(ramp[mid * width + 224]), center \(center), max jump \(maxJump), "
              + "decrease \(maxDecrease), rim bias \(leftBias)/\(rightBias))")
        exit(1)
    }

    var step = [Float](repeating: 0.2, count: count)
    for y in 0..<height {
        for x in 128..<width { step[y * width + x] = 0.8 }
    }
    let stepped = runGuided(guide: step)
    let left = stepped[mid * width + 116], right = stepped[mid * width + 140]
    guard left < 4, right > 10 else {
        print("probe: GUIDED STEP-GUIDE EDGE LOST (left \(left), right \(right))")
        exit(1)
    }
    print("probe: guided depth regularizer ramps OK")
}

let args = CommandLine.arguments.dropFirst()
let urls = args.map { URL(fileURLWithPath: $0) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
print("probe: fusing \(urls.count) frames")
let cache = AlignmentCache()
let output = try! StackPipeline.fuse(urls: Array(urls), configuration: .init(), alignmentCache: cache)
print("probe: fused \(output.image.width)x\(output.image.height)")

Task { @MainActor in
    // 1. Retouch session source loading.
    let source = StackPipeline.makeSource(urls: Array(urls), transforms: cache.transforms(for: Array(urls)))
    let session = RetouchSession(result: output.image, depth: output.depth,
                                 sharpness: output.sharpness, source: source)
    var ticks = 0
    while session.sourceLoading && ticks < 300 {
        try? await Task.sleep(nanoseconds: 100_000_000)
        ticks += 1
    }
    guard !session.sourceLoading, session.sourceDisplay != nil else {
        print("probe: RETOUCH SOURCE STUCK"); exit(1)
    }
    print("probe: retouch source loaded after ~\(Double(ticks)/10)s")

    // 1a. PMax blend layer: builds on demand, becomes the brush source, and
    // toggling back returns to the frame that was selected.
    let frameBefore = session.sourceIndex
    session.togglePMaxLayer()
    ticks = 0
    while session.sourceLoading && ticks < 600 {
        try? await Task.sleep(nanoseconds: 100_000_000)
        ticks += 1
    }
    guard session.isPMaxSource, session.sourceDisplay != nil, session.sourceError == nil else {
        print("probe: PMAX LAYER FAILED (\(session.sourceError ?? "no image"))"); exit(1)
    }
    session.togglePMaxLayer()
    guard session.sourceIndex == frameBefore else {
        print("probe: PMAX TOGGLE DID NOT RESTORE FRAME"); exit(1)
    }
    print("probe: pmax blend layer OK")

    // 1a2. Leaving a *building* PMax layer for a cached frame must fully
    // supersede the build: its progress previews (low-res forming-pyramid
    // collapses) and its cancelled completion must not touch the pane state.
    // Shipped bug: the cache-hit selection path didn't bump the load
    // generation, so build stragglers passed the staleness guard — blurry
    // 1200px source pane (or a "Couldn't build" error) over a correct
    // full-res paint buffer.
    let session2 = RetouchSession(result: output.image, depth: output.depth,
                                  sharpness: output.sharpness, source: source)
    session2.selectSource(0)
    ticks = 0
    while session2.sourceLoading && ticks < 300 {
        try? await Task.sleep(nanoseconds: 100_000_000)
        ticks += 1
    }
    guard let cachedDisplay = session2.sourceDisplay, session2.sourceError == nil else {
        print("probe: PMAX-STOMP SETUP FRAME LOAD FAILED"); exit(1)
    }
    session2.togglePMaxLayer()   // build starts (fresh session: no pmax cache)
    session2.togglePMaxLayer()   // straight back to frame 0 — a cache hit
    guard session2.sourceIndex == 0, session2.sourceDisplay === cachedDisplay else {
        print("probe: PMAX-STOMP TOGGLE-BACK LOST THE FRAME"); exit(1)
    }
    // Let the superseded build run its course (progress events + cancelled
    // or completed finish) — none of it may leak into the pane.
    for _ in 0..<50 {
        try? await Task.sleep(nanoseconds: 100_000_000)
        guard session2.sourceDisplay === cachedDisplay, session2.sourceError == nil,
              session2.sourceStatus == nil, session2.sourceFloat != nil else {
            print("probe: PMAX BUILD STOMPED A SUPERSEDING SELECTION "
                  + "(display \(session2.sourceDisplay === cachedDisplay ? "kept" : "STOMPED"), "
                  + "error \(session2.sourceError ?? "nil"), "
                  + "status \(session2.sourceStatus ?? "nil"), "
                  + "float \(session2.sourceFloat == nil ? "NIL" : "kept"))")
            exit(1)
        }
    }
    print("probe: superseded pmax build leaks nothing OK")

    // 1a2b. User-facing PMax-build cancel (cancelPMaxBuild): falls back to
    // the last frame source, and the cancelled build leaks nothing. The
    // pre-cancel state is deterministic: no await between selectKind(.pmax)
    // and the cancel, so the build's main-actor completion cannot have
    // landed yet even if the fuse itself finished.
    let session3 = RetouchSession(result: output.image, depth: output.depth,
                                  sharpness: output.sharpness, source: source)
    session3.selectSource(2)
    ticks = 0
    while session3.sourceLoading && ticks < 300 {
        try? await Task.sleep(nanoseconds: 100_000_000)
        ticks += 1
    }
    guard let frameDisplay = session3.sourceDisplay, session3.sourceError == nil else {
        print("probe: PMAX-CANCEL SETUP FRAME LOAD FAILED"); exit(1)
    }
    session3.selectKind(.pmax)
    guard session3.sourceKind == .pmax, session3.sourceLoading else {
        print("probe: PMAX-CANCEL BUILD NEVER STARTED"); exit(1)
    }
    session3.cancelPMaxBuild()
    guard session3.sourceKind == .frame, session3.sourceIndex == 2,
          session3.sourceDisplay === frameDisplay else {
        print("probe: PMAX-CANCEL DID NOT RESTORE THE FRAME SOURCE "
              + "(kind \(session3.sourceKind), index \(session3.sourceIndex))")
        exit(1)
    }
    // Drain the cancelled build — none of it may leak into the pane.
    for _ in 0..<50 {
        try? await Task.sleep(nanoseconds: 100_000_000)
        guard session3.sourceDisplay === frameDisplay, session3.sourceError == nil,
              session3.sourceStatus == nil, session3.sourceKind == .frame else {
            print("probe: CANCELLED PMAX BUILD LEAKED "
                  + "(error \(session3.sourceError ?? "nil"), "
                  + "status \(session3.sourceStatus ?? "nil"))")
            exit(1)
        }
    }
    print("probe: pmax build cancel OK")

    // 1a3. Result (eraser) layer: a stamp from a frame changes the working
    // pixels; an eraser stamp over the same spot restores the pristine fusion
    // exactly (inner-brush alpha is exactly 1), and toggling off returns to
    // the frame that was selected.
    session.selectSource(0)
    ticks = 0
    while session.sourceLoading && ticks < 300 {
        try? await Task.sleep(nanoseconds: 100_000_000)
        ticks += 1
    }
    guard !session.sourceLoading, session.sourceError == nil else {
        print("probe: ERASER TEST FRAME LOAD FAILED"); exit(1)
    }
    let cx = output.image.width / 2, cy = output.image.height / 2
    let brushPoint = CGPoint(x: cx, y: cy)
    session.brushRadius = 40  // softness 0.2 → inner radius 32; assert within 20
    func maxDiskDiff(_ a: [Float], _ b: [Float], radius: Int) -> Float {
        var m: Float = 0
        for y in (cy - radius)...(cy + radius) {
            for x in (cx - radius)...(cx + radius) where
                (x - cx) * (x - cx) + (y - cy) * (y - cy) <= radius * radius {
                let i = (y * output.image.width + x) * 4
                for c in 0..<3 { m = max(m, abs(a[i + c] - b[i + c])) }
            }
        }
        return m
    }
    // Depth co-painting: a stamp from frame 0 writes depth 0 under the
    // brush (inner-brush alpha is exactly 1), the eraser stamp restores the
    // fusion's depth exactly, and undo/redo replay both.
    func maxDepthDisk(_ depths: [Float], against reference: (Int) -> Float,
                      radius: Int) -> Float {
        var m: Float = 0
        for y in (cy - radius)...(cy + radius) {
            for x in (cx - radius)...(cx + radius) where
                (x - cx) * (x - cx) + (y - cy) * (y - cy) <= radius * radius {
                let i = y * output.image.width + x
                m = max(m, abs(depths[i] - reference(i)))
            }
        }
        return m
    }
    // The check below is only meaningful if the fusion's own depth here
    // differs from the painted value (0) — true for every synth fixture
    // (center depth is mid-stack), but say so if a fixture ever changes.
    if maxDepthDisk(output.depth, against: { _ in 0 }, radius: 20) < 0.5 {
        print("probe: WARNING depth-paint check vacuous (center depth ~0)")
    }
    session.beginStroke(at: brushPoint)
    session.endStroke()
    guard maxDiskDiff(session.working.pixels, output.image.pixels, radius: 20) > 0.005 else {
        print("probe: ERASER TEST STAMP DID NOT CHANGE PIXELS"); exit(1)
    }
    guard session.depthDirty,
          maxDepthDisk(session.workingDepth, against: { _ in 0 }, radius: 20) < 1e-4 else {
        print("probe: FRAME STAMP DID NOT PAINT DEPTH 0 (dirty \(session.depthDirty))")
        exit(1)
    }
    session.toggleResultLayer()
    guard session.isResultSource else {
        print("probe: ERASER LAYER NOT SELECTED"); exit(1)
    }
    // Paintable immediately — the float buffer needs no build, only the pane
    // preview renders asynchronously.
    session.beginStroke(at: brushPoint)
    session.endStroke()
    guard maxDiskDiff(session.working.pixels, output.image.pixels, radius: 20) < 1e-4 else {
        print("probe: ERASER DID NOT REVERT PIXELS"); exit(1)
    }
    guard maxDepthDisk(session.workingDepth, against: { output.depth[$0] },
                       radius: 20) < 1e-4 else {
        print("probe: ERASER DID NOT REVERT DEPTH"); exit(1)
    }
    // Undo pops the eraser stamp (depth back to the painted 0), redo
    // replays it (depth back to the fusion's).
    session.undo()
    guard maxDepthDisk(session.workingDepth, against: { _ in 0 }, radius: 20) < 1e-4 else {
        print("probe: UNDO DID NOT RESTORE PAINTED DEPTH"); exit(1)
    }
    session.redo()
    guard maxDepthDisk(session.workingDepth, against: { output.depth[$0] },
                       radius: 20) < 1e-4 else {
        print("probe: REDO DID NOT RESTORE ERASED DEPTH"); exit(1)
    }
    print("probe: depth co-painting (stamp/erase/undo/redo) OK")
    ticks = 0
    while session.sourceLoading && ticks < 100 {
        try? await Task.sleep(nanoseconds: 100_000_000)
        ticks += 1
    }
    guard session.sourceDisplay != nil, session.sourceError == nil else {
        print("probe: ERASER PREVIEW FAILED"); exit(1)
    }
    session.toggleResultLayer()
    guard session.sourceIndex == 0 else {
        print("probe: ERASER TOGGLE DID NOT RESTORE FRAME"); exit(1)
    }
    print("probe: eraser layer OK")

    // 1a4. PMax stamps leave the depth plane alone (their pixels have no
    // single depth), and Revert All restores the fusion's depth exactly.
    session.togglePMaxLayer()
    guard session.isPMaxSource, session.sourceFloat != nil else {
        print("probe: PMAX RESELECT LOST CACHE"); exit(1)
    }
    let depthBeforePMax = session.workingDepth
    session.beginStroke(at: brushPoint)
    session.endStroke()
    guard session.workingDepth == depthBeforePMax else {
        print("probe: PMAX STAMP TOUCHED DEPTH"); exit(1)
    }
    session.resetAll(to: output.image)
    guard session.workingDepth == output.depth, !session.hasEdits else {
        print("probe: REVERT ALL DID NOT RESTORE DEPTH"); exit(1)
    }
    print("probe: pmax depth non-interference + revert OK")


    // 1b. Missing source file (e.g. memory card unplugged) must surface a
    // diagnostic, not strand the spinner or show a generic hint.
    let ghostURLs = urls.map {
        $0.deletingLastPathComponent().appendingPathComponent("gone-\($0.lastPathComponent)")
    }
    let ghostSource = StackSource(urls: ghostURLs,
                                  transforms: cache.transforms(for: Array(urls)))
    let ghostSession = RetouchSession(result: output.image, depth: output.depth,
                                      sharpness: output.sharpness, source: ghostSource)
    ticks = 0
    while ghostSession.sourceLoading && ticks < 100 {
        try? await Task.sleep(nanoseconds: 100_000_000)
        ticks += 1
    }
    guard let ghostError = ghostSession.sourceError, ghostError.contains("missing") else {
        print("probe: MISSING-FILE ERROR NOT SURFACED (\(ghostSession.sourceError ?? "nil"))")
        exit(1)
    }
    print("probe: missing source diagnosed: \(ghostError)")

    // 2. Session serialization round-trip (v3: stacks array; the second
    // payload is unfused and must survive with no blobs).
    let sessionURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("probe.hyperfocal")
    let savedStack = ProjectStore.StackPayload(
        name: "probe-stack", frameURLs: Array(urls), includedURLs: Set(urls),
        transforms: cache.transforms(for: Array(urls)),
        result: output.image, depth: output.depth, sharpness: output.sharpness,
        working: output.image, sourceIndex: 3,
        gains: (0..<urls.count).map {
            SIMD3(1 + Float($0) * 0.01, 1 - Float($0) * 0.005, 1 + Float($0) * 0.002)
        })
    var unfusedStack = ProjectStore.StackPayload(
        name: "later", frameURLs: Array(urls.prefix(3)),
        includedURLs: Set(urls.prefix(2)), transforms: nil, result: nil)
    unfusedStack.enabled = false
    var savedTone = ToneSettings()
    savedTone.exposure = 2
    savedTone.shadows = 60
    var tonedStack = savedStack
    tonedStack.tone = savedTone
    tonedStack.crop = [40, 30, 200, 150]
    tonedStack.cropAngle = 8
    let saved = ProjectStore.Project(stacks: [tonedStack, unfusedStack], selectedIndex: 0)
    try! ProjectStore.write(saved, to: sessionURL)
    let restoredProject = try! ProjectStore.read(from: sessionURL)
    func maxDiff(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(0) { max($0, abs($1.0 - $1.1)) }
    }
    assert(restoredProject.stacks.count == 2, "stack count differs")
    assert(restoredProject.selectedIndex == 0)
    let restored = restoredProject.stacks[0]
    assert(restored.result!.pixels.count == output.image.pixels.count)
    assert(maxDiff(restored.result!.pixels, output.image.pixels) <= 1.0 / 65535 + 1e-6,
           "result pixels beyond 16-bit quantization")
    assert(maxDiff(restored.depth, output.depth) <= 1.0 / 64 + 1e-6,
           "depth beyond fixed-point quantization")
    assert(maxDiff(restored.working!.pixels, output.image.pixels) <= 1.0 / 65535 + 1e-6,
           "working beyond quantization")
    if restored.includedURLs != Set(urls) {
        print("probe: INCLUDED DIFFERS")
        print("  missing: \(Set(urls).subtracting(restored.includedURLs).map(\.path).sorted())")
        print("  extra:   \(restored.includedURLs.subtracting(Set(urls)).map(\.path).sorted())")
        exit(1)
    }
    assert(restored.sourceIndex == 3)
    assert(restored.gains == savedStack.gains, "exposure gains differ")
    // Gains manifest mapping: legacy scalar files expand to equal channels;
    // gainsRGB wins when both fields are present (new writers emit both).
    var legacyManifest = ProjectStore.StackManifest(
        name: "legacy", enabled: true, framePaths: [], includedPaths: [],
        transforms: nil, hasResult: false, resultWidth: 0, resultHeight: 0,
        hasWorking: false, sourceIndex: nil, gains: [1.25, 0.8],
        fusedSettings: nil, sharpnessFactor: nil, sharpnessFullWidth: nil,
        sharpnessFullHeight: nil, sharpnessFrameCount: nil, sharpnessScale: nil)
    assert(ProjectStore.gains(from: legacyManifest)
           == [SIMD3(repeating: 1.25), SIMD3(repeating: 0.8)],
           "legacy scalar gains must expand to equal channels")
    legacyManifest.gainsRGB = [[1.1, 1.0, 0.9], [1.0, 1.0, 1.0]]
    assert(ProjectStore.gains(from: legacyManifest)
           == [SIMD3(1.1, 1.0, 0.9), SIMD3(repeating: 1.0)],
           "gainsRGB must win over the legacy field")
    print("probe: gains manifest mapping OK")
    // Frame-order sanity check: mismatch when capture order and filename
    // order disagree, undated when any stamp is missing, quiet otherwise
    // (and always quiet in explicit name-order mode).
    let orderURLs = ["a.tif", "b.tif", "c.tif"].map { URL(fileURLWithPath: "/x/\($0)") }
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let inOrder: [Date?] = [t0, t0.addingTimeInterval(1), t0.addingTimeInterval(2)]
    let shuffled: [Date?] = [t0.addingTimeInterval(2), t0, t0.addingTimeInterval(1)]
    let undated: [Date?] = [t0, nil, t0.addingTimeInterval(2)]
    assert(StackSplitter.orderIssue(urls: orderURLs, dates: inOrder,
                                    byCaptureTime: true) == nil,
           "clean stack must not warn")
    assert(StackSplitter.orderIssue(urls: orderURLs, dates: shuffled,
                                    byCaptureTime: true) == .mismatch,
           "shuffled stack must warn mismatch")
    assert(StackSplitter.orderIssue(urls: orderURLs, dates: undated,
                                    byCaptureTime: true) == .undated,
           "undated stack must warn undated")
    assert(StackSplitter.orderIssue(urls: orderURLs, dates: shuffled,
                                    byCaptureTime: false) == nil,
           "explicit name-order mode never warns")
    print("probe: frame-order sanity OK")
    // Stage ETA: extrapolates only after 2 s of a stage with a real
    // fraction, resets on stage changes, and formats coarsely.
    let etaModel = AppModel()
    let e0 = Date(timeIntervalSince1970: 2_000_000)
    etaModel.updateStageETA(stage: .depth, fraction: 0.0, now: e0)
    assert(etaModel.stageETA == nil, "eta before any elapsed time")
    etaModel.updateStageETA(stage: .depth, fraction: 0.2,
                            now: e0.addingTimeInterval(4))
    assert(etaModel.stageETA == "~15s left",
           "eta at 20% after 4s: \(etaModel.stageETA ?? "nil")")
    etaModel.updateStageETA(stage: .render, fraction: 0.5,
                            now: e0.addingTimeInterval(5))
    assert(etaModel.stageETA == nil, "stage change must reset the eta")
    etaModel.updateStageETA(stage: .render, fraction: 0.02,
                            now: e0.addingTimeInterval(60))
    assert(etaModel.stageETA == nil, "tiny fractions extrapolate to nonsense")
    assert(AppModel.etaLabel(47) == "~45s left", "5 s rounding")
    assert(AppModel.etaLabel(200) == "~3 min left", "minute rounding")
    assert(AppModel.etaLabel(1.5) == nil, "sub-3s eta drops the label")
    print("probe: stage eta OK")
    assert(restored.transforms?.count == urls.count, "transforms count")
    if let sa = restored.sharpness, let sb = output.sharpness {
        let ga = sa.regionScores(centerX: 100, centerY: 100, radius: 60)
        let gb = sb.regionScores(centerX: 100, centerY: 100, radius: 60)
        let bestA = ga.indices.max { ga[$0] < ga[$1] }
        let bestB = gb.indices.max { gb[$0] < gb[$1] }
        assert(bestA == bestB, "sharpness argmax changed under quantization")
    }
    assert(restored.tone == savedTone, "tone settings differ after round-trip")
    let restoredUnfused = restoredProject.stacks[1]
    assert(restoredUnfused.result == nil && restoredUnfused.enabled == false,
           "unfused stack round-trip")
    assert(restoredUnfused.frameURLs.count == 3, "unfused frames")
    assert(restoredUnfused.tone == nil, "neutral stack should carry no tone")
    print("probe: project round-trip OK (fused + unfused stacks, tone)")

    // The container must be a standards-conforming zip, not merely one our
    // own reader accepts — users will point other tools at these files.
    func runUnzip(_ arguments: [String]) -> Bool {
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = arguments
        unzip.standardOutput = Pipe()
        unzip.standardError = Pipe()
        do { try unzip.run() } catch { return false }
        unzip.waitUntilExit()
        return unzip.terminationStatus == 0
    }
    guard runUnzip(["-t", "-qq", sessionURL.path]) else {
        print("probe: PROJECT NOT A VALID ZIP"); exit(1)
    }
    print("probe: project zip verified externally OK")

    // A project with no fused stack at all must round-trip too (Save is
    // not gated on having fused anything): manifest-only zip, no blobs.
    let unfusedOnlyURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("probe-unfused.hyperfocal")
    try! ProjectStore.write(ProjectStore.Project(stacks: [unfusedStack]),
                            to: unfusedOnlyURL)
    let unfusedOnly = try! ProjectStore.read(from: unfusedOnlyURL)
    assert(unfusedOnly.stacks.count == 1 && unfusedOnly.stacks[0].result == nil,
           "unfused-only project round-trip")
    try? FileManager.default.removeItem(at: unfusedOnlyURL)
    print("probe: unfused-only project round-trip OK")

    // 3. Model-level fuse + explicit project restore (autosave/autoload is
    // gone — writing the blobs at quit took too long; quit warns instead).
    let model = AppModel()
    model.ingest(urls: Array(urls))
    ticks = 0
    while model.phase.isRunning && ticks < 100 {
        try? await Task.sleep(nanoseconds: 100_000_000)
        ticks += 1
    }
    guard model.stacks.count == 1, model.frames.count == urls.count else {
        print("probe: INGEST WRONG (stacks=\(model.stacks.count))"); exit(1)
    }
    model.fuse()
    ticks = 0
    while model.phase != .done && ticks < 600 {
        try? await Task.sleep(nanoseconds: 100_000_000)
        ticks += 1
    }
    guard model.phase == .done else {
        print("probe: MODEL FUSE FAILED (\(model.phase))"); exit(1)
    }
    guard model.hasUnsavedWork else {
        print("probe: FUSE DID NOT MARK UNSAVED WORK"); exit(1)
    }
    // Staleness gate: right after a fuse nothing has changed, so Fuse is
    // disabled; a parameter change re-enables it; reverting disables again;
    // a frame-set change re-enables it too.
    guard !model.canFuse else {
        print("probe: FUSE ENABLED WITH NOTHING CHANGED"); exit(1)
    }
    let sigmaBefore = model.sharpnessSigma
    model.sharpnessSigma = sigmaBefore + 0.5
    guard model.canFuse else {
        print("probe: SETTINGS CHANGE DID NOT RE-ENABLE FUSE"); exit(1)
    }
    model.sharpnessSigma = sigmaBefore
    guard !model.canFuse else {
        print("probe: SETTINGS REVERT DID NOT DISABLE FUSE"); exit(1)
    }
    model.setIncluded(urls[0], to: false)
    guard model.canFuse else {
        print("probe: FRAME CHANGE DID NOT RE-ENABLE FUSE"); exit(1)
    }
    model.setIncluded(urls[0], to: true)
    // The GPU toggle counts as dirty too — it exists for when the GPU path
    // misbehaves, so switching engines must offer a re-fuse.
    if MetalEngine.shared != nil {
        model.useGPU.toggle()
        guard model.canFuse else {
            print("probe: GPU TOGGLE DID NOT RE-ENABLE FUSE"); exit(1)
        }
        model.useGPU.toggle()
        guard !model.canFuse else {
            print("probe: GPU REVERT DID NOT DISABLE FUSE"); exit(1)
        }
    }
    print("probe: model fused (staleness gate OK)")

    // Noise-floor preview: the predicted depth map renders (async) and clears.
    // A rapid burst of drag ticks exercises the coalescing path: computes are
    // serialized, mid-compute ticks fold into one follow-up, stale fits abort.
    model.beginNoiseFloorPreview()
    for i in 0..<30 {
        model.noiseFloor = 0.05 + Double(i) * 0.01
    }
    model.noiseFloor = 0.5
    ticks = 0
    while model.noiseFloorPreview == nil && ticks < 100 {
        try? await Task.sleep(nanoseconds: 100_000_000)
        ticks += 1
    }
    guard let previewImage = model.noiseFloorPreview else {
        print("probe: NOISE FLOOR PREVIEW MISSING"); exit(1)
    }
    if let tiff = NSBitmapImageRep(cgImage: previewImage)
        .representation(using: .tiff, properties: [:]) {
        try? tiff.write(to: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nf_preview.tiff"))
    }
    model.endNoiseFloorPreview()
    guard model.noiseFloorPreview == nil else {
        print("probe: PREVIEW DID NOT CLEAR"); exit(1)
    }
    // Changing the slider after end must NOT resurrect the overlay.
    model.noiseFloor = 0.05
    try? await Task.sleep(nanoseconds: 300_000_000)
    guard model.noiseFloorPreview == nil else {
        print("probe: PREVIEW RESURRECTED AFTER END"); exit(1)
    }
    print("probe: noise floor preview OK")

    // 3a1. Retouch depth merge: strokes co-paint the depth plane, and
    // leaving retouch folds it into resultDepth (what saves, the depth
    // export, and the rocking animation read). Reverting and re-merging
    // restores the fusion's plane, leaving the model pristine for the
    // checks below.
    let depthBeforeRetouch = model.resultDepth
    let mw = model.result!.width, mh = model.result!.height
    model.enterRetouch()
    guard let mergeSession = model.retouch else {
        print("probe: ENTER RETOUCH FAILED"); exit(1)
    }
    mergeSession.selectSource(0)
    ticks = 0
    while mergeSession.sourceLoading && ticks < 300 {
        try? await Task.sleep(nanoseconds: 100_000_000)
        ticks += 1
    }
    guard mergeSession.sourceFloat != nil else {
        print("probe: DEPTH-MERGE SOURCE STUCK"); exit(1)
    }
    mergeSession.brushRadius = 40
    mergeSession.beginStroke(at: CGPoint(x: mw / 2, y: mh / 2))
    mergeSession.endStroke()
    model.exitRetouch()
    let mci = (mh / 2) * mw + mw / 2
    guard abs(model.resultDepth[mci]) < 1e-4,
          abs(depthBeforeRetouch[mci]) > 0.5 else {
        print("probe: RETOUCH DEPTH NOT MERGED (\(model.resultDepth[mci]) "
              + "was \(depthBeforeRetouch[mci]))")
        exit(1)
    }
    model.resetRetouch()
    model.exitRetouch()  // merge again after the revert
    guard model.resultDepth == depthBeforeRetouch else {
        print("probe: REVERTED DEPTH DID NOT MERGE BACK"); exit(1)
    }
    print("probe: retouch depth merge OK")

    // 3a2. Undo/redo of non-stroke edits: a tone slider gesture is one
    // step however many ticks it delivered, frame inclusion records, and
    // the crop transaction records on Accept — ⌘Z's model path walks each
    // back exactly and redo replays it.
    let tone0 = model.tone
    model.toneEditing(true)
    model.tone.exposure = 1.25
    model.tone.shadows = 30
    model.toneEditing(false)
    guard model.canUndoEdit, model.undoMenuTitle == "Undo Tone Adjustment" else {
        print("probe: TONE GESTURE DID NOT RECORD (\(model.undoMenuTitle))"); exit(1)
    }
    model.undoEdit()
    guard model.tone == tone0 else {
        print("probe: UNDO DID NOT RESTORE TONE"); exit(1)
    }
    model.redoEdit()
    guard model.tone.exposure == 1.25, model.tone.shadows == 30 else {
        print("probe: REDO DID NOT REPLAY TONE"); exit(1)
    }
    model.undoEdit()  // leave tone pristine for the checks below

    let included0 = model.included
    model.setIncluded(urls[2], to: false)
    guard model.undoMenuTitle == "Undo Frame Selection" else {
        print("probe: INCLUSION DID NOT RECORD"); exit(1)
    }
    model.undoEdit()
    guard model.included == included0 else {
        print("probe: UNDO DID NOT RESTORE INCLUSION"); exit(1)
    }

    let probeCrop = CGRect(x: 12, y: 8, width: 320, height: 240)
    model.beginCrop()
    guard model.cropMode, !model.canUndoEdit else {
        print("probe: CROP MODE SHOULD SUSPEND EDIT UNDO"); exit(1)
    }
    model.cropRect = probeCrop
    model.acceptCrop()
    guard model.cropRect == probeCrop, model.undoMenuTitle == "Undo Crop" else {
        print("probe: CROP ACCEPT DID NOT RECORD"); exit(1)
    }
    model.undoEdit()
    guard model.cropRect == nil else {
        print("probe: UNDO DID NOT CLEAR CROP"); exit(1)
    }
    model.redoEdit()
    guard model.cropRect == probeCrop else {
        print("probe: REDO DID NOT RESTORE CROP"); exit(1)
    }
    model.undoEdit()  // leave uncropped
    // A cancelled crop is no edit at all.
    let undoCount0 = model.undoHistory.count
    model.beginCrop()
    model.cropRect = probeCrop
    model.cancelCrop()
    guard model.cropRect == nil, model.undoHistory.count == undoCount0 else {
        print("probe: CANCELLED CROP RECORDED AN EDIT"); exit(1)
    }
    print("probe: edit undo/redo OK")

    let model2 = AppModel()
    // The probe's project has no bookmarks, but every frame is readable
    // (unsandboxed) — the access re-grant prompt firing here would be a
    // false positive (it must key on actual read denial, not on missing
    // bookmarks).
    model2.accessPromptOverride = { count in
        print("probe: UNEXPECTED ACCESS RE-GRANT PROMPT (\(count) folders)")
        exit(1)
    }
    model2.openProject(from: sessionURL)
    ticks = 0
    while model2.phase != .done && ticks < 300 {
        try? await Task.sleep(nanoseconds: 100_000_000)
        ticks += 1
    }
    guard model2.phase == .done, model2.result != nil, model2.stacks.count == 2,
          model2.frames.count == urls.count, !model2.hasUnsavedWork else {
        print("probe: RESTORE FAILED (\(model2.phase), frames=\(model2.frames.count))")
        exit(1)
    }
    print("probe: project restored — frames=\(model2.frames.count), result \(model2.result!.width)x\(model2.result!.height)")
    try? FileManager.default.removeItem(at: sessionURL)

    // 3a2. Crop round-trips through the project, and exports honor it: the
    // written file must have exactly the crop's dimensions, and clearing
    // the crop must restore full-canvas exports.
    guard model2.cropRect == CGRect(x: 40, y: 30, width: 200, height: 150),
          model2.cropAngle == 8 else {
        print("probe: CROP LOST IN ROUND TRIP (\(String(describing: model2.cropRect)), "
              + "angle \(model2.cropAngle))")
        exit(1)
    }
    let cropExport = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("probe-crop.tif")
    guard model2.writeExport(to: cropExport),
          let croppedOut = try? ImageFile.load(url: cropExport),
          croppedOut.width == 200, croppedOut.height == 150 else {
        print("probe: CROPPED EXPORT WRONG SIZE"); exit(1)
    }
    model2.cropRect = nil
    guard model2.hasUnsavedWork else {
        print("probe: CLEARING CROP DID NOT MARK UNSAVED"); exit(1)
    }
    guard model2.writeExport(to: cropExport),
          let fullOut = try? ImageFile.load(url: cropExport),
          fullOut.width == model2.result!.width,
          fullOut.height == model2.result!.height else {
        print("probe: UNCROPPED EXPORT WRONG SIZE"); exit(1)
    }
    try? FileManager.default.removeItem(at: cropExport)
    print("probe: crop round-trip and cropped export OK")
    // 3b. Input pane with a selected-but-missing frame must explain itself
    // (the reported bug: it showed "Select a frame in the Stack list").
    let model3 = AppModel()
    model3.ingest(urls: ghostURLs)
    ticks = 0
    while model3.phase.isRunning && ticks < 100 {
        try? await Task.sleep(nanoseconds: 100_000_000)
        ticks += 1
    }
    model3.selection = [ghostURLs[0]]
    model3.selectionChanged()
    ticks = 0
    while model3.inputPreviewLoading && ticks < 100 {
        try? await Task.sleep(nanoseconds: 100_000_000)
        ticks += 1
    }
    guard let inputHint = model3.inputPreviewError, inputHint.contains("missing") else {
        print("probe: INPUT PANE ERROR NOT SURFACED (\(model3.inputPreviewError ?? "nil"))")
        exit(1)
    }
    print("probe: missing input frame diagnosed: \(inputHint)")

    // 4. Cancellation: cancel mid-fusion, expect CancellationError promptly.
    // 50ms: early enough to land inside registration even now that the whole
    // warm pipeline on this tiny stack finishes in a few hundred ms.
    let token = CancellationToken()
    let cancelStart = Date()
    Task.detached { try? await Task.sleep(nanoseconds: 50_000_000); token.cancel() }
    do {
        _ = try StackPipeline.fuse(urls: Array(urls), configuration: .init(),
                                   cancellation: token)
        print("probe: CANCEL DID NOT THROW"); exit(1)
    } catch is CancellationError {
        print("probe: cancelled after \(String(format: "%.2f", -cancelStart.timeIntervalSinceNow))s")
    } catch {
        print("probe: WRONG ERROR \(error)"); exit(1)
    }

    // 5. Bad-frame robustness: a near-black misfire and a bumped (non-rigid)
    // frame are detected during registration, excluded, and the remaining
    // stack still fuses close to ground truth.
    let sabotageDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("probe-sabotage-\(ProcessInfo.processInfo.processIdentifier)")
    let sabotageOptions = SynthStack.Options(width: 600, height: 400, frames: 11,
                                             maxBlur: 5, breathing: 0.02, jitter: 2,
                                             misfireFrame: 2, bumpFrame: 7)
    let (sabTruthURL, sabURLs) = try! SynthStack.generate(options: sabotageOptions,
                                                          outDir: sabotageDir)
    var sabConfig = StackPipeline.Configuration()
    sabConfig.autoExcludeBadFrames = true
    let sabResult = try! StackPipeline.fuseResult(urls: sabURLs, configuration: sabConfig)
    guard Set(sabResult.issues.map(\.index)) == [2, 7],
          sabResult.fusedURLs.count == sabURLs.count - 2 else {
        print("probe: BAD FRAMES NOT DETECTED (\(sabResult.issues.map(\.index)))"); exit(1)
    }
    let sabTruth = try! ImageFile.load(url: sabTruthURL)
    let sabPSNR = Metrics.psnrBestOffset(sabResult.output.image, sabTruth, margin: 32).psnr
    guard sabPSNR > 30 else {
        print("probe: SABOTAGED FUSE TOO LOSSY (\(sabPSNR) dB)"); exit(1)
    }
    print(String(format: "probe: bad-frame auto-exclusion OK (2 flagged, %.1f dB)", sabPSNR))

    // 5b. Model level: the prompt decides, excluded frames lose their checkbox
    // but stay listed with a reason badge.
    let model4 = AppModel()
    model4.badFramePrompt = { lines in lines.count == 2 }
    model4.ingest(urls: sabURLs)
    ticks = 0
    while model4.phase.isRunning && ticks < 100 {
        try? await Task.sleep(nanoseconds: 100_000_000)
        ticks += 1
    }
    model4.fuse()
    ticks = 0
    while model4.phase != .done && ticks < 600 {
        try? await Task.sleep(nanoseconds: 100_000_000)
        ticks += 1
    }
    guard model4.phase == .done else {
        print("probe: SABOTAGED MODEL FUSE FAILED (\(model4.phase))"); exit(1)
    }
    guard model4.frameIssues.count == 2,
          model4.included.count == sabURLs.count - 2,
          model4.frames.count == sabURLs.count else {
        print("probe: BAD FRAMES NOT FLAGGED (issues=\(model4.frameIssues.count), included=\(model4.included.count))")
        exit(1)
    }
    try? FileManager.default.removeItem(at: sabotageDir)
    print("probe: bad-frame model flow OK")

    // 6. Session auto-split + batch queue: two capture-time-stamped stacks in
    // one list split at the gap, batch-fuse serially, and export two results.
    let pid = ProcessInfo.processInfo.processIdentifier
    let sessionDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("probe-session-\(pid)")
    try? FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
    for (prefix, start) in [("a", 1_000_000_000.0), ("b", 1_000_000_600.0)] {
        let stackDir = sessionDir.appendingPathComponent("gen-\(prefix)")
        let options = SynthStack.Options(width: 500, height: 350, frames: 7,
                                         maxBlur: 4, breathing: 0.01, jitter: 1,
                                         captureStart: Date(timeIntervalSince1970: start),
                                         captureSpacing: 0.5)
        let (_, generated) = try! SynthStack.generate(options: options, outDir: stackDir)
        for url in generated {
            try! FileManager.default.copyItem(
                at: url, to: sessionDir.appendingPathComponent("\(prefix)_\(url.lastPathComponent)"))
        }
        try? FileManager.default.removeItem(at: stackDir)
    }
    let sessionURLs = try! FileManager.default
        .contentsOfDirectory(at: sessionDir, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "tif" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    let groups = StackSplitter.split(urls: sessionURLs)
    guard groups.count == 2, groups[0].count == 7, groups[1].count == 7,
          groups[0].allSatisfy({ $0.lastPathComponent.hasPrefix("a_") }) else {
        print("probe: SESSION SPLIT WRONG (\(groups.map(\.count)))"); exit(1)
    }
    // Undated frames must never split (a wrong split is worse than none).
    guard StackSplitter.split(urls: sessionURLs,
                              dates: sessionURLs.map { _ in nil }, gap: 10).count == 1 else {
        print("probe: UNDATED FRAMES SPLIT"); exit(1)
    }
    print("probe: session split OK (7 + 7 frames)")

    // 6b. Multi-stack model flow: ingest the session directory (recursive
    // scan; split dialog answered "Separate Stacks" via the probe override),
    // queue-fuse the enabled stacks, then export all fused results.
    let exportDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("probe-batch-out-\(pid)")
    try? FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
    let model5 = AppModel()
    var askedSplit = 0
    model5.splitChoicePrompt = { _, _ in askedSplit += 1; return true }
    model5.queueSummaryPresenter = { print("probe: queue summary: \($0)") }
    model5.ingest(urls: [sessionDir])
    ticks = 0
    while model5.phase.isRunning && ticks < 100 {
        try? await Task.sleep(nanoseconds: 100_000_000)
        ticks += 1
    }
    guard model5.stacks.count == 2, askedSplit == 1,
          model5.stacks[0].frames.count == 7, model5.stacks[1].frames.count == 7,
          model5.selectedStackID == model5.stacks[0].id else {
        print("probe: MULTI-STACK INGEST WRONG (stacks=\(model5.stacks.count), asked=\(askedSplit))")
        exit(1)
    }
    model5.fuseEnabledStacks()
    ticks = 0
    // The queue task starts asynchronously; wait on the outcome, then for
    // the queue to fully wind down.
    while model5.fusedStackCount < 2 && ticks < 1200 {
        try? await Task.sleep(nanoseconds: 100_000_000)
        ticks += 1
    }
    while (model5.batchStatus != nil || model5.phase.isRunning) && ticks < 1200 {
        try? await Task.sleep(nanoseconds: 100_000_000)
        ticks += 1
    }
    guard model5.fusedStackCount == 2 else {
        print("probe: QUEUE DID NOT FUSE BOTH (\(model5.fusedStackCount))"); exit(1)
    }
    // Switching stacks swaps state without loss: stack 1 must come back with
    // its own result, and stack 2's must survive the round trip.
    let secondID = model5.stacks[1].id
    let firstID = model5.stacks[0].id
    model5.selectStack(firstID)
    guard model5.result != nil, model5.frames == model5.stacks[0].frames else {
        print("probe: STACK SWITCH LOST STATE"); exit(1)
    }
    model5.selectStack(secondID)
    guard model5.result != nil else {
        print("probe: SECOND STACK LOST RESULT"); exit(1)
    }
    let exportSummary = await model5.exportAllFused(to: exportDir)
    let exported = (try? FileManager.default.contentsOfDirectory(
        at: exportDir, includingPropertiesForKeys: nil)) ?? []
    guard exportSummary.hasPrefix("2 stacks exported"), exported.count == 2 else {
        print("probe: EXPORT ALL FAILED (\(exportSummary); files=\(exported.count))")
        exit(1)
    }
    try? FileManager.default.removeItem(at: sessionDir)
    try? FileManager.default.removeItem(at: exportDir)
    print("probe: multi-stack ingest + queue + export-all OK")

    // 6b. Close Stack / Close Project. Closing the selected (fused, unsaved)
    // stack asks once, removes it, and selects the neighbor; closing the
    // project asks once and returns to the fresh-launch state.
    var confirmations = [String]()
    model5.confirmAlertOverride = { message in
        confirmations.append(message)
        return true
    }
    model5.closeSelectedStack()  // selected = second stack, fused, unsaved
    guard model5.stacks.count == 1, model5.selectedStackID == firstID,
          model5.result != nil, confirmations.count == 1 else {
        print("probe: CLOSE STACK WRONG (stacks=\(model5.stacks.count), "
              + "confirms=\(confirmations))")
        exit(1)
    }
    model5.closeProject()
    guard model5.stacks.isEmpty, model5.selectedStackID == nil,
          model5.phase == .empty, model5.result == nil,
          !model5.hasUnsavedWork, confirmations.count == 2 else {
        print("probe: CLOSE PROJECT WRONG (phase=\(model5.phase), "
              + "confirms=\(confirmations))")
        exit(1)
    }
    print("probe: close stack / close project OK")

    // 7. Frame ordering: capture time beats filename when the camera's
    // counter rolls over mid-stack; filename wins when the setting is off or
    // any frame is undated.
    let day = { (i: Int) in Date(timeIntervalSince1970: Double(i)) }
    let named = { (names: [String]) in names.map { URL(fileURLWithPath: "/t/\($0).nef") } }
    let rolled = named(["DSC_9998", "DSC_9999", "DSC_0000", "DSC_0001"])
    let captureOrder = StackSplitter.ordered(
        urls: [rolled[2], rolled[0], rolled[3], rolled[1]],
        dates: [day(3), day(1), day(4), day(2)], byCaptureTime: true)
    guard captureOrder == rolled else {
        print("probe: ROLLOVER ORDER WRONG (\(captureOrder.map(\.lastPathComponent)))")
        exit(1)
    }
    let nameOrder = StackSplitter.ordered(urls: rolled, dates: [day(1), day(2), day(3), day(4)],
                                          byCaptureTime: false)
    guard nameOrder.map(\.lastPathComponent) == ["DSC_0000.nef", "DSC_0001.nef",
                                                 "DSC_9998.nef", "DSC_9999.nef"] else {
        print("probe: NAME ORDER WRONG (\(nameOrder.map(\.lastPathComponent)))"); exit(1)
    }
    guard StackSplitter.ordered(urls: rolled, dates: [day(1), nil, day(3), day(4)],
                                byCaptureTime: true) == nameOrder else {
        print("probe: UNDATED FRAMES REORDERED"); exit(1)
    }
    // EXIF DateTimeOriginal is second-resolution; same-second frames must
    // fall back to name order among themselves (stable for sub-second bursts
    // from cameras that omit SubsecTimeOriginal).
    guard StackSplitter.ordered(urls: [rolled[1], rolled[0]], dates: [day(1), day(1)],
                                byCaptureTime: true) == [rolled[0], rolled[1]] else {
        print("probe: SAME-SECOND TIE NOT NAME-BROKEN"); exit(1)
    }

    // 7b. Model flow: ingest a rollover-named stack (EXIF survives the file
    // copies) under both settings. The setting persists in the real defaults
    // suite, so restore whatever the user had.
    let rolloverGen = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("probe-rollover-gen-\(pid)")
    let rolloverDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("probe-rollover-\(pid)")
    try? FileManager.default.createDirectory(at: rolloverDir, withIntermediateDirectories: true)
    // Whole-second spacing: EXIF DateTimeOriginal has second resolution, so
    // sub-second spacing would collapse into ties (covered above) and muddy
    // the rollover expectation.
    let rollOptions = SynthStack.Options(width: 500, height: 350, frames: 7,
                                         maxBlur: 4, breathing: 0.01, jitter: 1,
                                         captureStart: Date(timeIntervalSince1970: 2_000_000_000),
                                         captureSpacing: 1)
    let (_, rollFrames) = try! SynthStack.generate(options: rollOptions, outDir: rolloverGen)
    var rolledNames = [String]()  // capture order: DSC_9997 … DSC_0003
    for (i, url) in rollFrames.enumerated() {
        let name = String(format: "DSC_%04d.tif", (9997 + i) % 10000)
        rolledNames.append(name)
        try! FileManager.default.copyItem(at: url,
                                          to: rolloverDir.appendingPathComponent(name))
    }
    try? FileManager.default.removeItem(at: rolloverGen)
    let model6 = AppModel()
    let savedOrderSetting = model6.orderByCaptureTime
    defer { model6.orderByCaptureTime = savedOrderSetting }
    for (byCapture, expected) in [(true, rolledNames), (false, rolledNames.sorted())] {
        model6.orderByCaptureTime = byCapture
        model6.ingest(urls: [rolloverDir])
        ticks = 0
        while model6.phase.isRunning && ticks < 100 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            ticks += 1
        }
        guard model6.frames.map(\.lastPathComponent) == expected else {
            print("probe: INGEST ORDER WRONG (byCapture=\(byCapture): "
                  + "\(model6.frames.map(\.lastPathComponent)))")
            exit(1)
        }
    }
    try? FileManager.default.removeItem(at: rolloverDir)
    print("probe: rollover frame ordering OK (capture-time + filename modes)")

    // Re-fusing after the source files vanish must fail loudly with a
    // useful message — not "complete" leaving the stale result on screen.
    let vanishDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("probe-vanish-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.createDirectory(at: vanishDir, withIntermediateDirectories: true)
    for url in urls {
        try? FileManager.default.copyItem(at: url,
                                          to: vanishDir.appendingPathComponent(url.lastPathComponent))
    }
    let model7 = AppModel()
    model7.ingest(urls: [vanishDir])
    ticks = 0
    while model7.phase.isRunning && ticks < 100 {
        try? await Task.sleep(nanoseconds: 100_000_000)
        ticks += 1
    }
    model7.fuse()
    ticks = 0
    while model7.phase != .done && ticks < 600 {
        try? await Task.sleep(nanoseconds: 100_000_000)
        ticks += 1
    }
    guard model7.phase == .done else {
        print("probe: VANISH BASELINE FUSE FAILED (\(model7.phase))"); exit(1)
    }
    try? FileManager.default.removeItem(at: vanishDir)
    var failureMessage: String? = nil
    model7.fuseFailureAlertOverride = { failureMessage = $0 }
    model7.sharpnessSigma += 1  // staleness gate: make the re-fuse allowed
    model7.fuse()
    ticks = 0
    while model7.phase.isRunning && ticks < 300 {
        try? await Task.sleep(nanoseconds: 100_000_000)
        ticks += 1
    }
    guard case .failed(let failText) = model7.phase, failText.contains("missing"),
          let alerted = failureMessage, alerted.contains("missing") else {
        print("probe: VANISHED SOURCES NOT REPORTED (phase \(model7.phase), "
              + "alert \(failureMessage ?? "none"))")
        exit(1)
    }
    print("probe: vanished-source fuse reported: \(failText.prefix(60))…")

    // DNG exports with edited tone must gain a Camera Raw .xmp sidecar
    // carrying the settings; neutral tone must not.
    let xmp = XMPSidecar.cameraRawXMP(for: {
        var t = ToneSettings()
        t.exposure = 0.85
        t.shadows = 42
        return t
    }())
    guard xmp.contains("crs:Exposure2012=\"+0.85\""),
          xmp.contains("crs:Shadows2012=\"+42\""),
          xmp.contains("crs:Contrast2012=\"+0\""),
          xmp.contains("crs:HasSettings=\"True\"") else {
        print("probe: XMP SIDECAR CONTENT WRONG:\n\(xmp)"); exit(1)
    }
    let dngDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("probe-dng-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.createDirectory(at: dngDir, withIntermediateDirectories: true)
    model.exportFormat = .dng
    var probeTone = ToneSettings()
    probeTone.exposure = 0.85
    probeTone.shadows = 42
    model.tone = probeTone
    let summary = await model.exportAllFused(to: dngDir)
    let dng = dngDir.appendingPathComponent("\(model.stacks[0].name).dng")
    guard let dngData = try? Data(contentsOf: dng),
          dngData.range(of: Data("crs:Exposure2012=\"+0.85\"".utf8)) != nil,
          dngData.range(of: Data("crs:Shadows2012=\"+42\"".utf8)) != nil else {
        print("probe: DNG EMBEDDED XMP MISSING OR WRONG (\(summary))"); exit(1)
    }
    // The patched DNG must still open (relocated IFD0 intact).
    guard let reread = try? ImageFile.load(url: dng),
          reread.width > 0 else {
        print("probe: PATCHED DNG UNREADABLE"); exit(1)
    }
    model.tone = ToneSettings()
    try? FileManager.default.removeItem(at: dngDir)
    try? FileManager.default.createDirectory(at: dngDir, withIntermediateDirectories: true)
    _ = await model.exportAllFused(to: dngDir)
    guard let neutralData = try? Data(contentsOf: dng),
          neutralData.range(of: Data("crs:".utf8)) == nil else {
        print("probe: NEUTRAL TONE STILL EMBEDDED XMP"); exit(1)
    }
    print("probe: dng embedded tone xmp OK")

    // Both DNG writers must declare a linear render: an explicit linear
    // ProfileToneCurve (50940) and DefaultBlackRender=None (51110). A
    // profile without them doesn't render linearly — ACR substitutes its
    // default S-curve and shadow mapping on top of the baked-in look.
    func hasLinearRenderTags(_ data: Data) -> Bool {
        func u16(_ o: Int) -> Int { Int(data[o]) | Int(data[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        guard data.count > 8, data[0] == 0x49 else { return false }
        let ifd = u32(4)
        var curveOK = false, blackOK = false
        for i in 0..<u16(ifd) {
            let o = ifd + 2 + i * 12
            switch u16(o) {
            case 50940:
                let off = u32(o + 8)
                curveOK = u32(o + 4) == 6 && (0..<6).map {
                    Float(bitPattern: UInt32(truncatingIfNeeded: u32(off + $0 * 4)))
                } == [0, 0, 0.5, 0.5, 1, 1]
            case 51110:
                blackOK = u32(o + 8) == 1
            default:
                break
            }
        }
        return curveOK && blackOK
    }
    guard hasLinearRenderTags(neutralData) else {
        print("probe: SDK DNG MISSING LINEAR RENDER TAGS"); exit(1)
    }
    let fallbackDNG = dngDir.appendingPathComponent("fallback.dng")
    try? DNGWriter.writeUncompressed(reread, to: fallbackDNG)
    guard let fallbackData = try? Data(contentsOf: fallbackDNG),
          hasLinearRenderTags(fallbackData) else {
        print("probe: FALLBACK DNG MISSING LINEAR RENDER TAGS"); exit(1)
    }
    try? FileManager.default.removeItem(at: dngDir)
    print("probe: dng linear render tags OK")

    // Portable simd shim: Float3x3 (the non-Apple stand-in for simd_float3x3,
    // used on Windows/Linux) must match Apple's simd here, entry for entry,
    // across the operations the engine relies on — construction, column
    // subscript, matrix×vector, matrix×matrix, and inverse. This is the
    // shim's correctness gate; on macOS both types are available so we diff
    // them directly.
    do {
        func close(_ a: Float, _ b: Float) -> Bool {
            abs(a - b) <= 1e-3 * max(1, abs(a), abs(b))
        }
        let testRows: [[SIMD3<Float>]] = [
            [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)],
            [SIMD3(1.2, -0.3, 30), SIMD3(0.25, 0.9, -15), SIMD3(0, 0, 1)],
            [SIMD3(0.8, 0.1, 12), SIMD3(-0.2, 1.05, -7), SIMD3(0.0004, -0.0007, 1)],
        ]
        let vectors = [SIMD3<Float>(10, 20, 1), SIMD3<Float>(-3, 7, 1)]
        for rows in testRows {
            let apple = simd_float3x3(rows: rows)
            let port = Float3x3(rows: rows)
            func fail(_ what: String) { print("probe: PORTABLE SIMD \(what) MISMATCH"); exit(1) }
            // Column subscript M[col][row] must agree (column-major, like simd).
            for c in 0..<3 { for r in 0..<3 where !close(apple[c][r], port[c][r]) { fail("subscript") } }
            for v in vectors {
                let pa = apple * v, pp = port * v
                if !close(pa.x, pp.x) || !close(pa.y, pp.y) || !close(pa.z, pp.z) { fail("mat*vec") }
            }
            let ai = apple.inverse, pi = port.inverse
            for c in 0..<3 { for r in 0..<3 where !close(ai[c][r], pi[c][r]) { fail("inverse") } }
        }
        // Matrix×matrix and identity equality.
        let a = simd_float3x3(rows: testRows[1]), b = simd_float3x3(rows: testRows[2])
        let pa = Float3x3(rows: testRows[1]), pb = Float3x3(rows: testRows[2])
        let ab = a * b, pab = pa * pb
        for c in 0..<3 { for r in 0..<3 where !close(ab[c][r], pab[c][r]) {
            print("probe: PORTABLE SIMD mat*mat MISMATCH"); exit(1)
        } }
        guard Float3x3.identity == Float3x3(rows: testRows[0]) else {
            print("probe: PORTABLE SIMD identity MISMATCH"); exit(1)
        }
        print("probe: portable simd shim OK")
    }

    print("probe: ALL PASS")
    exit(0)
}
RunLoop.main.run()
