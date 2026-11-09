import Foundation

/// One unit of derived knowledge about a photo.
///
/// Stages are independent and idempotent: an asset carrying only `.metadata`
/// and `.embedding` is already searchable, and a stage can be re-run at any
/// time without disturbing the others.
public enum IndexStage: String, Sendable, Codable, CaseIterable, Comparable {
    case metadata
    case embedding
    case labels
    case text
    case faces

    /// Ascending cost, which is also the order the pipeline runs them in.
    public var cost: Int {
        switch self {
        case .metadata: 0
        case .embedding: 1
        case .labels: 2
        case .text: 3
        case .faces: 4
        }
    }

    public static func < (lhs: IndexStage, rhs: IndexStage) -> Bool {
        lhs.cost < rhs.cost
    }
}

/// A stage paired with the extractor revision that satisfies it.
///
/// Bumping the version invalidates every stored result for that stage without
/// touching the others, which is how a model upgrade becomes a background
/// re-index rather than a rebuild.
public struct StageRequirement: Hashable, Sendable, Codable {
    public let stage: IndexStage
    public let version: Int

    public init(stage: IndexStage, version: Int) {
        self.stage = stage
        self.version = version
    }
}

public struct StageCompletion: Hashable, Sendable, Codable {
    public let assetID: AssetID
    public let stage: IndexStage
    public let version: Int
    public let completedAt: Date

    public init(assetID: AssetID, stage: IndexStage, version: Int, completedAt: Date = .now) {
        self.assetID = assetID
        self.stage = stage
        self.version = version
        self.completedAt = completedAt
    }
}
