import Foundation
import PicknickCore
import PicknickSearch
import PicknickStore
import PicknickTestSupport
import Testing

private struct StubTextEmbedder: TextEmbedder {
    let model: String
    let vectors: [String: [Float]]

    func embed(_ text: String) async throws -> Embedding {
        Embedding(model: model, values: vectors[text] ?? [])
    }
}

private func makeStore(_ batch: IndexBatch) async throws -> SQLiteIndexStore {
    let store = SQLiteIndexStore.inMemory()
    try await store.prepare()
    try await store.commit(batch)
    return store
}

private func embedding(_ id: AssetID, _ values: [Float], model: String = "clip") -> FeatureRecord {
    FeatureRecord(assetID: id, value: .embedding(Embedding(model: model, values: values)))
}

private func label(_ id: AssetID, _ identifier: String, _ confidence: Float = 0.9) -> FeatureRecord {
    FeatureRecord(assetID: id, value: .labels([Label(identifier: identifier, confidence: confidence)]))
}

private func text(_ id: AssetID, _ content: String) -> FeatureRecord {
    FeatureRecord(assetID: id, value: .text(RecognizedText(lines: [.init(content: content, confidence: 1, boundingBox: .unit)])))
}

@Suite("Search engine")
struct SearchEngineTests {
    @Test("Semantic results rank by cosine similarity, independent of vector length")
    func cosineOrder() async throws {
        let store = try await makeStore(
            IndexBatch(
                metadata: ["exact", "near", "orthogonal", "opposite"].map { .fixture(id: AssetID($0)) },
                features: [
                    embedding("exact", [10, 0]),
                    embedding("near", [0.7, 0.7]),
                    embedding("orthogonal", [0, 0.5]),
                    embedding("opposite", [-1, 0]),
                ]
            )
        )
        let embedder = StubTextEmbedder(model: "clip", vectors: ["sunset": [1, 0.1]])
        let engine = SearchEngine(index: store, embedder: embedder, configuration: .init(minimumSimilarity: 0))

        let results = try await engine.search(SearchQuery("sunset"))

        #expect(results.map(\.id) == ["exact", "near", "orthogonal"])
        #expect(results.allSatisfy { $0.ranks.keys.contains(.semantic) })
    }

    @Test("Vectors from another model are never scored")
    func singleModel() async throws {
        let store = try await makeStore(
            IndexBatch(
                metadata: [.fixture(id: "mine"), .fixture(id: "foreign")],
                features: [embedding("mine", [0, 1]), embedding("foreign", [1, 0], model: "other")]
            )
        )
        let engine = SearchEngine(index: store, embedder: StubTextEmbedder(model: "clip", vectors: ["q": [1, 0]]), configuration: .init(minimumSimilarity: 0))

        let results = try await engine.search(SearchQuery("q"))

        #expect(results.map(\.id) == ["mine"])
    }

    @Test("Without an embedder, labels and recognized text still answer")
    func noEmbedder() async throws {
        let store = try await makeStore(
            IndexBatch(
                metadata: [.fixture(id: "dog"), .fixture(id: "sign"), .fixture(id: "both"), .fixture(id: "cat")],
                features: [
                    label("dog", "dog"),
                    text("sign", "beware of the dog"),
                    label("both", "dog"),
                    text("both", "dog park"),
                    label("cat", "cat"),
                    embedding("cat", [1, 0]),
                ]
            )
        )
        let engine = SearchEngine(index: store)

        let results = try await engine.search(SearchQuery("photos of a dog"))

        #expect(results.first?.id == "both")
        #expect(Set(results.map(\.id)) == ["dog", "sign", "both"])
        #expect(results.allSatisfy { !$0.ranks.keys.contains(.semantic) })
    }

    @Test("Hybrid fusion promotes an asset found by several signals")
    func hybrid() async throws {
        let store = try await makeStore(
            IndexBatch(
                metadata: [.fixture(id: "visual"), .fixture(id: "labelled")],
                features: [
                    embedding("visual", [1, 0, 0]),
                    embedding("labelled", [0, 1, 0]),
                    label("labelled", "beach"),
                ]
            )
        )
        // Realistic CLIP cosines: 0.22 for "visual", 0.20 for "labelled".
        let engine = SearchEngine(index: store, embedder: StubTextEmbedder(model: "clip", vectors: ["beach": [0.22, 0.20, 0.9548]]))

        let results = try await engine.search(SearchQuery("beach"))

        #expect(results.map(\.id) == ["labelled", "visual"])
        #expect(results[0].ranks == [.semantic: 2, .label: 1])
    }

    @Test("Filters apply to every signal")
    func filtersApplyEverywhere() async throws {
        let store = try await makeStore(
            IndexBatch(
                metadata: [.fixture(id: "kept", isFavorite: true), .fixture(id: "dropped")],
                features: [
                    embedding("kept", [0, 1]),
                    embedding("dropped", [1, 0]),
                    label("dropped", "boat"),
                    text("dropped", "boat"),
                ]
            )
        )
        let engine = SearchEngine(index: store, embedder: StubTextEmbedder(model: "clip", vectors: ["boat": [1, 0.2]]), configuration: .init(minimumSimilarity: 0))

        let results = try await engine.search(SearchQuery("boat", filter: SearchFilter(isFavorite: true)))

        #expect(results.map(\.id) == ["kept"])
    }

    @Test("A query with no text lists filtered assets newest first")
    func filterOnly() async throws {
        let assets = AssetMetadata.sequence(count: 3)
        let store = try await makeStore(IndexBatch(metadata: assets))
        let engine = SearchEngine(index: store)

        let results = try await engine.search(SearchQuery("  ", limit: 2))

        #expect(results.map(\.id) == ["asset-2", "asset-1"])
        #expect(results.allSatisfy { Set($0.ranks.keys) == [.filter] })
    }

    @Test("Results are capped at the query limit")
    func limit() async throws {
        let assets = AssetMetadata.sequence(count: 5)
        let store = try await makeStore(
            IndexBatch(metadata: assets, features: assets.map { label($0.id, "tree") })
        )
        let engine = SearchEngine(index: store)

        #expect(try await engine.search(SearchQuery("tree", limit: 3)).count == 3)
    }

    @Test("Newly committed embeddings are searchable without a manual reset")
    func cacheInvalidation() async throws {
        let store = try await makeStore(
            IndexBatch(metadata: [.fixture(id: "a"), .fixture(id: "b")], features: [embedding("a", [1, 0])])
        )
        let engine = SearchEngine(index: store, embedder: StubTextEmbedder(model: "clip", vectors: ["q": [1, 0]]))
        #expect(try await engine.search(SearchQuery("q")).map(\.id) == ["a"])

        try await store.commit(IndexBatch(features: [embedding("b", [1, 0.01])]))
        #expect(try await engine.search(SearchQuery("q")).map(\.id) == ["a", "b"])

        try await store.commit(IndexBatch(removals: ["a"]))
        #expect(try await engine.search(SearchQuery("q")).map(\.id) == ["b"])
    }

    @Test("Place names match regardless of case and diacritics")
    func placeSearch() async throws {
        let store = try await makeStore(
            IndexBatch(
                metadata: [
                    .fixture(id: "lisbon", coordinate: Coordinate(latitude: 38.72, longitude: -9.14)),
                    .fixture(id: "reykjavik", coordinate: Coordinate(latitude: 64.15, longitude: -21.94)),
                    .fixture(id: "nowhere"),
                ],
                features: [label("nowhere", "harbor")],
                placeTerms: [
                    "lisbon": ["Lisbon", "Lisbon District", "Portugal"],
                    "reykjavik": ["Reykjavík", "Capital Region", "Iceland"],
                ]
            )
        )
        let engine = SearchEngine(index: store)

        let lisbon = try await engine.search(SearchQuery("photos in Lisbon"))
        #expect(lisbon.map(\.id) == ["lisbon"])
        #expect(Set(lisbon[0].ranks.keys) == [.place])

        #expect(try await engine.search(SearchQuery("reykjavik")).map(\.id) == ["reykjavik"])
        #expect(try await engine.search(SearchQuery("REYKJAVÍK")).map(\.id) == ["reykjavik"])
        #expect(try await engine.search(SearchQuery("harbor")).map(\.id) == ["nowhere"])
    }
}

@Suite("Search engine: empty matches")
struct SearchEmptyMatchTests {
    @Test("A query made only of stop words returns nothing, not the whole library")
    func stopWordsOnly() async throws {
        let store = try await makeStore(IndexBatch(metadata: AssetMetadata.sequence(count: 3)))
        let engine = SearchEngine(index: store)

        #expect(try await engine.search(SearchQuery("photos")).isEmpty)
    }

    @Test("Results below the minimum probability are dropped")
    func similarityFloor() async throws {
        let store = try await makeStore(
            IndexBatch(
                metadata: [.fixture(id: "near"), .fixture(id: "far")],
                features: [embedding("near", [1, 0]), embedding("far", [0, 1])]
            )
        )
        let engine = SearchEngine(index: store, embedder: StubTextEmbedder(model: "clip", vectors: ["q": [1, 0.05]]))

        #expect(try await engine.search(SearchQuery("q", minimumProbability: 0.5)).map(\.id) == ["near"])
    }
}

@Suite("Search engine: signal weights")
struct SignalWeightTests {
    @Test("An exact text hit outranks a semantic-only neighbour")
    func textOutweighsSemantic() async throws {
        let store = try await makeStore(
            IndexBatch(
                metadata: [.fixture(id: "lookalike"), .fixture(id: "recipe")],
                features: [embedding("lookalike", [1, 0]), embedding("recipe", [0, 1]), text("recipe", "lentil soup")]
            )
        )
        let engine = SearchEngine(index: store, embedder: StubTextEmbedder(model: "clip", vectors: ["lentil soup": [0.25, 0.9682]]))

        #expect(try await engine.search(SearchQuery("lentil soup")).first?.id == "recipe")
    }
}

@Suite("Search engine: place phrases")
struct PlacePhraseTests {
    @Test("A multi-word place matches as a phrase, not word by word")
    func phraseBeforeWords() async throws {
        let store = try await makeStore(
            IndexBatch(
                metadata: [.fixture(id: "nyc"), .fixture(id: "sydney"), .fixture(id: "york")],
                placeTerms: [
                    "nyc": ["New York City", "New York", "United States"],
                    "sydney": ["Sydney", "New South Wales", "Australia"],
                    "york": ["York", "England", "United Kingdom"],
                ]
            )
        )
        let engine = SearchEngine(index: store)

        #expect(try await engine.search(SearchQuery("new york")).map(\.id) == ["nyc"])
        #expect(Set(try await engine.search(SearchQuery("york")).map(\.id)) == ["nyc", "york"])
    }
}

@Suite("Search engine: probabilities")
struct ProbabilityTests {
    /// Cosine 0.30, 0.22, 0.15 and -0.30 against a, b, c and d.
    static let query: [Float] = [0.30, 0.22, 0.15, 0.9268]

    private func store() async throws -> SQLiteIndexStore {
        try await makeStore(
            IndexBatch(
                metadata: ["a", "b", "c", "d"].map { .fixture(id: AssetID($0)) },
                features: [
                    embedding("a", [1, 0, 0, 0]),
                    embedding("b", [0, 1, 0, 0]),
                    embedding("c", [0, 0, 1, 0]),
                    embedding("d", [-1, 0, 0, 0]),
                ]
            )
        )
    }

    @Test("Results are ordered by probability and every probability is within 0...1")
    func orderedProbabilities() async throws {
        let engine = SearchEngine(index: try await store(), embedder: StubTextEmbedder(model: "clip", vectors: ["q": Self.query]))

        let results = try await engine.search(SearchQuery("q"))

        #expect(results.map(\.id) == ["a", "b", "c"], "d has negative cosine, below the candidate floor")
        #expect(results.allSatisfy { (0...1).contains($0.score) })
        #expect(zip(results, results.dropFirst()).allSatisfy { $0.score >= $1.score })
    }

    @Test("Top N returns exactly N when enough results clear the minimum")
    func topN() async throws {
        let engine = SearchEngine(index: try await store(), embedder: StubTextEmbedder(model: "clip", vectors: ["q": Self.query]))

        #expect(try await engine.search(SearchQuery("q", limit: 2)).map(\.id) == ["a", "b"])
        #expect(try await engine.search(SearchQuery("q", minimumProbability: 0.5)).map(\.id) == ["a", "b"])
        #expect(try await engine.search(SearchQuery("q", minimumProbability: 0.999)).isEmpty)
    }

    @Test("Semantic probability follows the calibration curve")
    func calibration() {
        let configuration = SearchEngine.Configuration()

        #expect(abs(configuration.semanticProbability(0.2) - 0.74) < 0.01)
        #expect(configuration.semanticProbability(0.1) < 0.02)
        #expect(configuration.semanticProbability(0.3) > 0.99)
    }

    @Test("Several weak signals combine into a stronger match")
    func noisyOr() async throws {
        let store = try await makeStore(
            IndexBatch(
                metadata: [.fixture(id: "both"), .fixture(id: "label")],
                features: [label("both", "dog", 0.5), text("both", "dog"), label("label", "dog", 0.5)]
            )
        )
        let results = try await SearchEngine(index: store).search(SearchQuery("dog"))

        #expect(results.map(\.id) == ["both", "label"])
        #expect(abs(results[0].score - (1 - 0.5 * 0.01)) < 1e-9)
        #expect(abs(results[1].score - 0.5) < 1e-9)
    }
}

@Suite("Search engine: well-known places")
struct KnownPlaceTests {
    private func store() async throws -> SQLiteIndexStore {
        try await makeStore(
            IndexBatch(
                metadata: [.fixture(id: "pizza-tokyo"), .fixture(id: "street-tokyo"), .fixture(id: "pizza-home")],
                features: [
                    embedding("pizza-tokyo", [1, 0]),
                    embedding("street-tokyo", [0, 1]),
                    embedding("pizza-home", [1, 0]),
                ],
                placeTerms: ["pizza-tokyo": ["Tokyo", "Japan"], "street-tokyo": ["Tokyo", "Japan"]]
            )
        )
    }

    private func engine(_ store: SQLiteIndexStore) -> SearchEngine {
        SearchEngine(
            index: store,
            embedder: StubTextEmbedder(model: "clip", vectors: ["vietnam": [1, 0], "pizza": [1, 0]]),
            placeVocabulary: PlaceNameIndexStub(["tokyo", "japan", "vietnam"])
        )
    }

    @Test("A known place with no photos there returns nothing, even if a photo looks similar")
    func noPhotosThere() async throws {
        #expect(try await engine(try await store()).search(SearchQuery("vietnam")).isEmpty)
    }

    @Test("A known place lists the photos taken there")
    func photosThere() async throws {
        let ids = try await engine(try await store()).search(SearchQuery("photos in Tokyo")).map(\.id)
        #expect(Set(ids) == ["pizza-tokyo", "street-tokyo"])
    }

    @Test("Content plus a known place keeps only photos from that place")
    func contentInPlace() async throws {
        let results = try await engine(try await store()).search(SearchQuery("pizza in tokyo", minimumProbability: 0.5))
        #expect(results.map(\.id) == ["pizza-tokyo"])
    }
}

private struct PlaceNameIndexStub: PlaceVocabulary {
    let names: Set<String>
    init(_ names: [String]) { self.names = Set(names) }
    func isPlaceName(_ phrase: String) -> Bool { names.contains(phrase) }
}
