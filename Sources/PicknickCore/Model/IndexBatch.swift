import Foundation

/// One atomic unit of index progress.
///
/// The store commits a batch in a single transaction, which is what lets the
/// process be killed at any moment without leaving a half-indexed asset: work
/// either lands whole or is redone on the next pass.
public struct IndexBatch: Sendable {
    public var metadata: [AssetMetadata]
    public var features: [FeatureRecord]
    public var completions: [StageCompletion]
    public var failures: [StageFailure]
    public var removals: [AssetID]
    /// Place names for assets in `metadata`. An asset in `metadata` with no
    /// entry here has its stored place names cleared.
    public var placeTerms: [AssetID: [String]]

    public init(
        metadata: [AssetMetadata] = [],
        features: [FeatureRecord] = [],
        completions: [StageCompletion] = [],
        failures: [StageFailure] = [],
        removals: [AssetID] = [],
        placeTerms: [AssetID: [String]] = [:]
    ) {
        self.metadata = metadata
        self.features = features
        self.completions = completions
        self.failures = failures
        self.removals = removals
        self.placeTerms = placeTerms
    }

    public var isEmpty: Bool {
        metadata.isEmpty && features.isEmpty && completions.isEmpty
            && failures.isEmpty && removals.isEmpty
    }

    public mutating func merge(_ other: IndexBatch) {
        metadata.append(contentsOf: other.metadata)
        features.append(contentsOf: other.features)
        completions.append(contentsOf: other.completions)
        failures.append(contentsOf: other.failures)
        removals.append(contentsOf: other.removals)
        placeTerms.merge(other.placeTerms) { _, new in new }
    }
}

public struct StageFailure: Hashable, Sendable, Codable {
    public let assetID: AssetID
    public let stage: IndexStage
    public let reason: String
    public let isPermanent: Bool
    public let occurredAt: Date

    public init(
        assetID: AssetID,
        stage: IndexStage,
        reason: String,
        isPermanent: Bool,
        occurredAt: Date = .now
    ) {
        self.assetID = assetID
        self.stage = stage
        self.reason = reason
        self.isPermanent = isPermanent
        self.occurredAt = occurredAt
    }
}
