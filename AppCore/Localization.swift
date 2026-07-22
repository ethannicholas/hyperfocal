import Foundation

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

extension AppModel.OutputMode: DisplayNamed {}
extension AppModel.CropAspect: DisplayNamed {}
extension AppModel.ExportFormat: DisplayNamed {}
extension AppModel.ExportColorSpace: DisplayNamed {}
extension AppModel.AnimationFormat: DisplayNamed {}
extension AppModel.AnimationPath: DisplayNamed {}
extension AppModel.AnimationStrength: DisplayNamed {}
extension AppModel.AnimationDuration: DisplayNamed {}
extension AppModel.AnimationFPS: DisplayNamed {}
