import Foundation

public enum PicknickError: Error, Sendable, Hashable {
    case notAuthorized(LibraryAuthorization)
    case assetNotFound(AssetID)
    /// Only a cloud copy exists and the request forbade network access.
    case assetUnavailableLocally(AssetID)
    case imageDecodingFailed(AssetID)
    case storeUnavailable(String)
    case storeFailure(operation: String, message: String)
    case extractionFailed(stage: IndexStage, message: String)
}

extension PicknickError: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .notAuthorized(status):
            "Photo library access is \(status)."
        case let .assetNotFound(id):
            "No asset with identifier \(id)."
        case let .assetUnavailableLocally(id):
            "Asset \(id) has no local copy and network access was not permitted."
        case let .imageDecodingFailed(id):
            "Could not decode an image for asset \(id)."
        case let .storeUnavailable(message):
            "Index store unavailable: \(message)"
        case let .storeFailure(operation, message):
            "Index store failed during \(operation): \(message)"
        case let .extractionFailed(stage, message):
            "Stage \(stage.rawValue) failed: \(message)"
        }
    }
}

extension PicknickError {
    /// Whether retrying could plausibly succeed. Permanent failures are
    /// recorded so the asset stops re-entering the queue.
    public var isPermanent: Bool {
        switch self {
        case .assetNotFound, .imageDecodingFailed:
            true
        case .notAuthorized, .assetUnavailableLocally, .storeUnavailable,
             .storeFailure, .extractionFailed:
            false
        }
    }
}
