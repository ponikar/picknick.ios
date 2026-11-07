import Foundation

/// What the index holds for one asset, gathered for display or explanation.
public struct AssetContext: Hashable, Sendable {
    public let metadata: AssetMetadata
    public let labels: [Label]
    public let text: RecognizedText?

    public init(metadata: AssetMetadata, labels: [Label] = [], text: RecognizedText? = nil) {
        self.metadata = metadata
        self.labels = labels
        self.text = text
    }
}

/// Per-asset reads for a handful of known ids.
///
/// Separate from `SearchableIndex` so adding it does not force every existing
/// search backend to implement it at once.
public protocol AssetContextReader: Sendable {
    /// Context for each id the index knows; unknown ids are omitted.
    func context(for ids: [AssetID]) async throws -> [AssetContext]
}
