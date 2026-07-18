import Foundation

/// Errors raised across the engine's fusion, spill, and I/O paths. Defined
/// here (not in `MetalEngine.swift`) so it stays available on platforms where
/// the Metal path is compiled out — `FrameSpill`, `RockingAnimation`, and the
/// CPU fusion fallbacks all raise it.
public enum StackError: Error, CustomStringConvertible {
    case metal(String)
    case io(String)

    public var description: String {
        switch self {
        case .metal(let s): return "metal: \(s)"
        case .io(let s): return "i/o: \(s)"
        }
    }
}
