import Foundation
import PicknickCore

/// Hybrid photo search over semantic similarity, labels, recognized text and
/// places. Every result carries a probability in 0...1 that it matches the
/// query; results are ordered by it and cut at the query's minimum.
///
/// Semantic retrieval is optional. Without a `TextEmbedder` the engine still
/// answers from labels, text, places and filters, which is what a device that
/// has not finished embedding its library can offer.
public actor SearchEngine {
    public struct Configuration: Sendable {
        /// How many candidates each signal contributes before scoring.
        public var retrievalDepth: Int
        /// Candidates below this cosine similarity are not scored at all.
        public var minimumSimilarity: Float
        /// Maps cosine similarity to P(relevant) as sigmoid(slope * cos + intercept).
        public var semanticSlope: Double
        public var semanticIntercept: Double
        /// Probability given to an exact OCR or place-name hit.
        public var exactMatchProbability: Double

        // Slope and intercept are a logistic fit of MobileCLIP-S2 cosine against
        // caption relevance: 298 COCO photos x 41 queries (EvalApp/EVALS.md).
        // cos 0.15 -> 0.17, 0.20 -> 0.74, 0.25 -> 0.98.
        public init(
            retrievalDepth: Int = 200,
            minimumSimilarity: Float = 0,
            semanticSlope: Double = 52.64,
            semanticIntercept: Double = -9.49,
            exactMatchProbability: Double = 0.99
        ) {
            self.retrievalDepth = retrievalDepth
            self.minimumSimilarity = minimumSimilarity
            self.semanticSlope = semanticSlope
            self.semanticIntercept = semanticIntercept
            self.exactMatchProbability = exactMatchProbability
        }

        public func semanticProbability(_ cosine: Float) -> Double {
            1 / (1 + exp(-(semanticSlope * Double(cosine) + semanticIntercept)))
        }
    }

    private let index: any SearchableIndex
    private let embedder: (any TextEmbedder)?
    private let placeVocabulary: (any PlaceVocabulary)?
    private let configuration: Configuration

    private var cachedMatrix: NormalizedMatrix?
    private var cachedRevision: Int?

    public init(
        index: any SearchableIndex,
        embedder: (any TextEmbedder)? = nil,
        placeVocabulary: (any PlaceVocabulary)? = nil,
        configuration: Configuration = .init()
    ) {
        self.index = index
        self.embedder = embedder
        self.placeVocabulary = placeVocabulary
        self.configuration = configuration
    }

    /// Drops the decoded embedding matrix; the next semantic search reloads it.
    public func invalidateCache() {
        cachedMatrix = nil
        cachedRevision = nil
    }

    public func search(_ query: SearchQuery) async throws -> [SearchResult] {
        guard query.limit > 0 else { return [] }
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let depth = max(configuration.retrievalDepth, query.limit)
        let words = QueryTerms.words(in: text)

        guard !text.isEmpty else {
            let listed = try await index.assets(matching: query.filter, limit: query.limit)
            return listed.map { SearchResult(id: $0, score: 1, ranks: [.filter: 1]) }
        }
        guard !words.isEmpty || embedder != nil else { return [] }

        let (knownPlaces, contentWords) = splitKnownPlaces(words)
        var evidence = Evidence()

        if knownPlaces.isEmpty {
            try await collect(text: text, words: words, filter: query.filter, depth: depth, into: &evidence)
            for (rank, id) in try await placeRanking(words: words, filter: query.filter, depth: depth).enumerated() {
                evidence.add(id, .place, rank: rank + 1, probability: configuration.exactMatchProbability)
            }
        } else {
            // A well-known place ("vietnam", "tokyo") is answered from GPS, never from
            // how a photo looks: CLIP rates some photo as "vietnam" in any library.
            let inPlace = try await index.placeMatches(knownPlaces, filter: query.filter, limit: depth).map(\.id)
            if contentWords.isEmpty {
                for (rank, id) in inPlace.enumerated() {
                    evidence.add(id, .place, rank: rank + 1, probability: configuration.exactMatchProbability)
                }
                for (rank, match) in try await index.textMatches(words, filter: query.filter, limit: depth).enumerated() {
                    evidence.add(match.id, .text, rank: rank + 1, probability: configuration.exactMatchProbability)
                }
            } else if !inPlace.isEmpty {
                try await collect(
                    text: contentWords.joined(separator: " "),
                    words: contentWords,
                    filter: query.filter,
                    depth: depth,
                    into: &evidence
                )
                evidence.restrict(to: Set(inPlace))
            }
        }

        return Array(
            evidence.results()
                .filter { $0.score >= query.minimumProbability }
                .prefix(query.limit)
        )
    }

    /// Semantic, label and OCR evidence for `text`.
    private func collect(text: String, words: [String], filter: SearchFilter, depth: Int, into evidence: inout Evidence) async throws {
        if let embedder {
            let hits = try await semanticHits(for: try await embedder.embed(text), filter: filter, depth: depth)
            for (rank, hit) in hits.enumerated() {
                evidence.add(hit.id, .semantic, rank: rank + 1, probability: configuration.semanticProbability(hit.cosine))
            }
        }
        guard !words.isEmpty else { return }
        let labels = try await index.labelMatches(QueryTerms.labelTerms(in: text), filter: filter, limit: depth)
        for (rank, match) in labels.enumerated() {
            evidence.add(match.id, .label, rank: rank + 1, probability: min(1, max(0, match.score)))
        }
        for (rank, match) in try await index.textMatches(words, filter: filter, limit: depth).enumerated() {
            evidence.add(match.id, .text, rank: rank + 1, probability: configuration.exactMatchProbability)
        }
    }

    /// Longest runs of query words that name a well-known place, and the words left over.
    private func splitKnownPlaces(_ words: [String]) -> (places: [String], rest: [String]) {
        guard let placeVocabulary, !words.isEmpty else { return ([], words) }
        var covered = Array(repeating: false, count: words.count)
        var places: [String] = []
        for length in stride(from: min(words.count, Self.maximumPlaceWords), through: 1, by: -1) {
            for start in 0...(words.count - length) where !covered[start..<(start + length)].contains(true) {
                let phrase = words[start..<(start + length)].joined(separator: " ")
                guard placeVocabulary.isPlaceName(phrase) else { continue }
                places.append(phrase)
                covered.replaceSubrange(start..<(start + length), with: repeatElement(true, count: length))
            }
        }
        let rest = words.indices.filter { !covered[$0] }.map { words[$0] }
        return (places, rest)
    }

    /// Matches the longest place phrases first, so "new york" does not also
    /// pull in every place containing "new" (New South Wales) or "york".
    private func placeRanking(words: [String], filter: SearchFilter, depth: Int) async throws -> [AssetID] {
        let words = Array(words.prefix(Self.maximumPlaceWords))
        var covered = Array(repeating: false, count: words.count)
        var phrases: [String] = []

        for length in stride(from: words.count, through: 1, by: -1) {
            for start in 0...(words.count - length) where !covered[start..<(start + length)].contains(true) {
                let phrase = words[start..<(start + length)].joined(separator: " ")
                guard try await !index.placeMatches([phrase], filter: filter, limit: 1).isEmpty else { continue }
                phrases.append(phrase)
                covered.replaceSubrange(start..<(start + length), with: repeatElement(true, count: length))
            }
        }

        guard !phrases.isEmpty else { return [] }
        return try await index.placeMatches(phrases, filter: filter, limit: depth).map(\.id)
    }

    private static let maximumPlaceWords = 5

    private func semanticHits(for query: Embedding, filter: SearchFilter, depth: Int) async throws -> [(id: AssetID, cosine: Float)] {
        guard query.dimensions > 0 else { return [] }
        let matrix = try await matrix(model: query.model, dimensions: query.dimensions)
        guard matrix.count > 0 else { return [] }

        let allowed = Set(try await index.assets(matching: filter, limit: nil))
        let scores = matrix.similarities(to: query.values)

        return scores.indices
            .filter { scores[$0] >= configuration.minimumSimilarity && allowed.contains(matrix.ids[$0]) }
            .sorted { scores[$0] != scores[$1] ? scores[$0] > scores[$1] : $0 < $1 }
            .prefix(depth)
            .map { (matrix.ids[$0], scores[$0]) }
    }

    /// The cached matrix holds exactly one model and size, so a query can
    /// never be scored against vectors from a different embedding space.
    private func matrix(model: String, dimensions: Int) async throws -> NormalizedMatrix {
        let revision = try await index.embeddingRevision()
        if let cachedMatrix, cachedRevision == revision,
           cachedMatrix.model == model, cachedMatrix.dimensions == dimensions {
            return cachedMatrix
        }

        let loaded = NormalizedMatrix(try await index.embeddings(model: model, dimensions: dimensions))
        cachedMatrix = loaded
        cachedRevision = revision
        return loaded
    }
}

/// Per-asset signal probabilities, combined with noisy-OR: an asset is a match
/// unless every signal that found it is wrong, P = 1 - Π(1 - p_i).
private struct Evidence {
    private var probabilities: [AssetID: [SearchSignal: Double]] = [:]
    private var ranks: [AssetID: [SearchSignal: Int]] = [:]

    mutating func add(_ id: AssetID, _ signal: SearchSignal, rank: Int, probability: Double) {
        guard ranks[id]?[signal] == nil else { return }
        ranks[id, default: [:]][signal] = rank
        probabilities[id, default: [:]][signal] = probability
    }

    mutating func restrict(to allowed: Set<AssetID>) {
        probabilities = probabilities.filter { allowed.contains($0.key) }
        ranks = ranks.filter { allowed.contains($0.key) }
    }

    func results() -> [SearchResult] {
        probabilities
            .map { id, bySignal in
                let miss = bySignal.values.reduce(1.0) { $0 * (1 - $1) }
                return SearchResult(id: id, score: 1 - miss, ranks: ranks[id] ?? [:])
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                let lhsBest = lhs.ranks.values.min() ?? .max
                let rhsBest = rhs.ranks.values.min() ?? .max
                if lhsBest != rhsBest { return lhsBest < rhsBest }
                return lhs.id.rawValue < rhs.id.rawValue
            }
    }
}
