import Foundation
import PicknickCore

public struct SearchQuery: Hashable, Sendable {
    public var text: String
    public var filter: SearchFilter
    /// Top N: the most results returned.
    public var limit: Int
    /// Results below this match probability (0...1) are dropped.
    public var minimumProbability: Double

    public init(_ text: String, filter: SearchFilter = .none, limit: Int = 100, minimumProbability: Double = 0) {
        self.text = text
        self.filter = filter
        self.limit = limit
        self.minimumProbability = minimumProbability
    }
}

/// The retrieval paths that can surface an asset.
public enum SearchSignal: String, Hashable, Sendable, CaseIterable {
    case semantic
    case label
    case text
    case place
    /// No free text was given, so assets are listed by filter alone.
    case filter
}

public struct SearchResult: Hashable, Sendable, Identifiable {
    public let id: AssetID
    /// Probability in 0...1 that the asset matches the query.
    public let score: Double
    /// 1-based rank of the asset within each signal that returned it.
    public let ranks: [SearchSignal: Int]

    public init(id: AssetID, score: Double, ranks: [SearchSignal: Int]) {
        self.id = id
        self.score = score
        self.ranks = ranks
    }
}
