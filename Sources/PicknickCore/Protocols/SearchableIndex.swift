import Foundation

/// Every stored embedding of one model and size, as a row-major matrix.
///
/// Flat storage rather than one array per asset keeps the whole library in a
/// single allocation the vector units can walk without pointer chasing.
public struct EmbeddingMatrix: Sendable {
    public let model: String
    public let dimensions: Int
    public let ids: [AssetID]
    public let values: [Float]

    public init(model: String, dimensions: Int, ids: [AssetID], values: [Float]) {
        precondition(values.count == ids.count * dimensions, "matrix shape does not match ids")
        self.model = model
        self.dimensions = dimensions
        self.ids = ids
        self.values = values
    }

    public var count: Int { ids.count }
}

/// A ranked hit from a lexical signal, best first.
public struct LexicalMatch: Hashable, Sendable {
    public let id: AssetID
    public let score: Double

    public init(id: AssetID, score: Double) {
        self.id = id
        self.score = score
    }
}

/// The read side of the index, kept apart from `IndexStore` so the indexer
/// never depends on search and a search UI never gets write access.
public protocol SearchableIndex: Sendable {
    /// Changes whenever stored embeddings may have changed, so a caller can
    /// keep a decoded matrix and know when to throw it away.
    func embeddingRevision() async throws -> Int

    /// Embeddings produced by exactly `model` at exactly `dimensions`.
    func embeddings(model: String, dimensions: Int) async throws -> EmbeddingMatrix

    /// Assets carrying any of `terms` as a label (case-insensitive, with
    /// underscores read as spaces), best summed confidence first.
    func labelMatches(_ terms: [String], filter: SearchFilter, limit: Int) async throws -> [LexicalMatch]

    /// Full-text hits over recognized text for any of `terms`, best first.
    func textMatches(_ terms: [String], filter: SearchFilter, limit: Int) async throws -> [LexicalMatch]

    /// Assets whose place names contain any of `terms`, ignoring case and
    /// diacritics, best first.
    func placeMatches(_ terms: [String], filter: SearchFilter, limit: Int) async throws -> [LexicalMatch]

    /// Assets passing `filter`, newest first. `nil` limit returns all of them.
    func assets(matching filter: SearchFilter, limit: Int?) async throws -> [AssetID]
}
