import Foundation

public enum LibraryAuthorization: Sendable, Hashable {
    case notDetermined
    case denied
    case restricted
    /// The user granted access to a chosen subset. The library is still fully
    /// usable; it is simply smaller than the device's real photo collection.
    case limited
    case authorized

    public var allowsReading: Bool {
        self == .limited || self == .authorized
    }
}

/// Read-only access to the host photo library.
///
/// The contract is deliberately narrow: enumerate cheaply, read metadata in
/// bulk, and publish a signal when something changes. Pixels are the separate
/// concern of `ImageLoader`.
public protocol PhotoLibrary: Sendable {
    var authorization: LibraryAuthorization { get async }

    @discardableResult
    func requestAuthorization() async -> LibraryAuthorization

    /// Every asset the app can see, as id and modification date only.
    ///
    /// This is the one full scan in the system. Implementations must not load
    /// pixels or resolve cloud resources here.
    func fingerprints() async throws -> [AssetID: AssetFingerprint]

    func metadata(for ids: [AssetID]) async throws -> [AssetMetadata]

    /// Fires when the library changes while the app is in the foreground.
    ///
    /// The signal carries no payload: the receiver responds by rescanning
    /// fingerprints, which is the same path used at launch.
    func changes() -> AsyncStream<Void>
}
