import Foundation
import HyperfocalKit

/// Display-name seam for option enums whose rawValues are persisted (and so
/// must never localize): UI shows `displayName`, storage keeps `rawValue`.
/// Lookup key = the English rawValue, resolved against the main bundle's
/// string catalog — headless consumers (probe, bridge, Linux) have no
/// catalog and fall back to the English key, which is exactly the old
/// behavior.
public protocol DisplayNamed: CaseIterable, Equatable {
    var displayName: String { get }
}

extension DisplayNamed where Self: RawRepresentable, RawValue == String {
    public var displayName: String { NSLocalizedString(rawValue, comment: "") }
}

// FusionMethod's rawValues ("dmap"/"pmax") are persisted + used on the CLI,
// so they can't double as display strings; "DMap"/"PMax" are proper algorithm
// names (never translated), so an explicit displayName overrides the default
// NSLocalizedString(rawValue) lookup.
extension FusionMethod: DisplayNamed {
    public var displayName: String {
        switch self {
        case .dmap: return "DMap"
        case .pmax: return "PMax"
        }
    }
}

extension AppModel.OutputMode: DisplayNamed {}
extension AppModel.CropAspect: DisplayNamed {}
extension AppModel.ExportFormat: DisplayNamed {}
extension AppModel.ExportColorSpace: DisplayNamed {}
extension AppModel.AnimationFormat: DisplayNamed {}
extension AppModel.AnimationPath: DisplayNamed {}
extension AppModel.AnimationStrength: DisplayNamed {}
extension AppModel.AnimationDuration: DisplayNamed {}
extension AppModel.AnimationFPS: DisplayNamed {}
