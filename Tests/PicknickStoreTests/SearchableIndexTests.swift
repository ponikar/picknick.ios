import Foundation
import PicknickCore
import PicknickStore
import PicknickTestSupport
import Testing

@Suite("SQLite searchable index")
struct SearchableIndexTests {
    private func makeStore(_ batch: IndexBatch) async throws -> SQLiteIndexStore {
        let store = SQLiteIndexStore.inMemory()
        try await store.prepare()
        try await store.commit(batch)
        return store
    }

    private func text(_ content: String) -> FeatureValue {
        .text(RecognizedText(lines: [.init(content: content, confidence: 1, boundingBox: .unit)]))
    }

    @Test("Embeddings come back for one model and size only")
    func embeddingsByModel() async throws {
        let store = try await makeStore(
            IndexBatch(
                metadata: [.fixture(id: "a"), .fixture(id: "b"), .fixture(id: "c")],
                features: [
                    FeatureRecord(assetID: "a", value: .embedding(Embedding(model: "clip", values: [0.25, -0.5]))),
                    FeatureRecord(assetID: "b", value: .embedding(Embedding(model: "other", values: [1, 0]))),
                    FeatureRecord(assetID: "c", value: .embedding(Embedding(model: "clip", values: [1, 0, 0]))),
                ]
            )
        )

        let matrix = try await store.embeddings(model: "clip", dimensions: 2)

        #expect(matrix.ids == ["a"])
        #expect(matrix.values == [0.25, -0.5])
    }

    @Test("Embedding revision moves when vectors change and not otherwise")
    func embeddingRevision() async throws {
        let store = try await makeStore(IndexBatch(metadata: [.fixture(id: "a")]))
        let initial = try await store.embeddingRevision()

        try await store.commit(IndexBatch(metadata: [.fixture(id: "a", isFavorite: true)]))
        #expect(try await store.embeddingRevision() == initial)

        try await store.commit(
            IndexBatch(features: [FeatureRecord(assetID: "a", value: .embedding(Embedding(model: "m", values: [1])))])
        )
        let afterEmbedding = try await store.embeddingRevision()
        #expect(afterEmbedding != initial)

        try await store.commit(IndexBatch(removals: ["a"]))
        #expect(try await store.embeddingRevision() != afterEmbedding)
    }

    @Test("Labels match case-insensitively and rank by summed confidence")
    func labelMatches() async throws {
        let store = try await makeStore(
            IndexBatch(
                metadata: [.fixture(id: "a"), .fixture(id: "b"), .fixture(id: "c")],
                features: [
                    FeatureRecord(assetID: "a", value: .labels([Label(identifier: "Dog", confidence: 0.4)])),
                    FeatureRecord(assetID: "b", value: .labels([
                        Label(identifier: "dog", confidence: 0.5),
                        Label(identifier: "golden_retriever", confidence: 0.3),
                    ])),
                    FeatureRecord(assetID: "c", value: .labels([Label(identifier: "cat", confidence: 0.9)])),
                ]
            )
        )

        let matches = try await store.labelMatches(["DOG", "golden retriever"], filter: .none, limit: 10)

        #expect(matches.map(\.id) == ["b", "a"])
    }

    @Test("Full-text search covers recognized text only and ranks by relevance")
    func textMatches() async throws {
        let store = try await makeStore(
            IndexBatch(
                metadata: [.fixture(id: "a"), .fixture(id: "b"), .fixture(id: "c")],
                features: [
                    FeatureRecord(assetID: "a", value: text("Total due 42.00 receipt")),
                    FeatureRecord(assetID: "b", value: text("receipt receipt coffee receipt")),
                    FeatureRecord(assetID: "c", value: .labels([Label(identifier: "receipt", confidence: 1)])),
                ]
            )
        )

        let matches = try await store.textMatches(["receipt"], filter: .none, limit: 10)

        #expect(matches.map(\.id) == ["b", "a"])
    }

    @Test("Text matching requires every term")
    func textMatchesRequireAllTerms() async throws {
        let store = try await makeStore(
            IndexBatch(
                metadata: [.fixture(id: "ticket"), .fixture(id: "menu")],
                features: [
                    FeatureRecord(assetID: "ticket", value: text("parking ticket plate KX")),
                    FeatureRecord(assetID: "menu", value: text("plate of food")),
                ]
            )
        )

        #expect(try await store.textMatches(["plate", "food"], filter: .none, limit: 10).map(\.id) == ["menu"])
    }

    @Test("Full-text input is never parsed as query syntax")
    func textMatchesEscapeSyntax() async throws {
        let store = try await makeStore(
            IndexBatch(metadata: [.fixture(id: "a")], features: [FeatureRecord(assetID: "a", value: text("hello"))])
        )

        let quoted = try await store.textMatches(["\"hello"], filter: .none, limit: 10)
        let operators = try await store.textMatches(["hello", "NEAR(", "*", "AND"], filter: .none, limit: 10)

        #expect(quoted.map(\.id) == ["a"])
        #expect(operators.isEmpty, "operators are literal terms, and text matching requires every term")
    }

    @Test("Filters constrain date, kind, traits, location, favorite and hidden")
    func filters() async throws {
        let base = Date(timeIntervalSinceReferenceDate: 700_000_000)
        var video = AssetMetadata.fixture(id: "video", createdAt: base.addingTimeInterval(10))
        video.kind = .video
        var hidden = AssetMetadata.fixture(id: "hidden", createdAt: base.addingTimeInterval(20))
        hidden.isHidden = true
        let store = try await makeStore(
            IndexBatch(metadata: [
                .fixture(id: "old", createdAt: base.addingTimeInterval(-86_400)),
                .fixture(id: "placed", createdAt: base.addingTimeInterval(30), coordinate: Coordinate(latitude: 1, longitude: 2)),
                .fixture(id: "favorite", createdAt: base.addingTimeInterval(40), isFavorite: true),
                .fixture(id: "screenshot", createdAt: base.addingTimeInterval(50), traits: [.screenshot]),
                video,
                hidden,
            ])
        )

        #expect(try await store.assets(matching: .none, limit: nil) == ["screenshot", "favorite", "placed", "video", "old"])
        #expect(try await store.assets(matching: .none, limit: 2) == ["screenshot", "favorite"])
        #expect(try await store.assets(matching: SearchFilter(includeHidden: true), limit: nil).contains("hidden"))
        #expect(try await store.assets(matching: SearchFilter(kinds: [.video]), limit: nil) == ["video"])
        #expect(try await store.assets(matching: SearchFilter(kinds: []), limit: nil).isEmpty)
        #expect(try await store.assets(matching: SearchFilter(requiredTraits: .screenshot), limit: nil) == ["screenshot"])
        #expect(try await store.assets(matching: SearchFilter(hasLocation: true), limit: nil) == ["placed"])
        #expect(try await store.assets(matching: SearchFilter(isFavorite: true), limit: nil) == ["favorite"])
        #expect(
            try await store.assets(
                matching: SearchFilter(createdIn: DateInterval(start: base, duration: 35)),
                limit: nil
            ) == ["placed", "video"]
        )
    }

    @Test("Lexical matches respect filters")
    func lexicalMatchesFiltered() async throws {
        let store = try await makeStore(
            IndexBatch(
                metadata: [.fixture(id: "a", isFavorite: true), .fixture(id: "b")],
                features: [
                    FeatureRecord(assetID: "a", value: text("menu")),
                    FeatureRecord(assetID: "b", value: text("menu")),
                    FeatureRecord(assetID: "a", value: .labels([Label(identifier: "food", confidence: 1)])),
                    FeatureRecord(assetID: "b", value: .labels([Label(identifier: "food", confidence: 1)])),
                ]
            )
        )
        let notFavorite = SearchFilter(isFavorite: false)

        #expect(try await store.textMatches(["menu"], filter: notFavorite, limit: 10).map(\.id) == ["b"])
        #expect(try await store.labelMatches(["food"], filter: notFavorite, limit: 10).map(\.id) == ["b"])
    }
}
