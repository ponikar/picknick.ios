import Foundation
import PicknickCore
import PicknickSearch
import PicknickStore
import PicknickTestSupport
import Testing

private struct Places: PlaceVocabulary {
    let names: Set<String>
    func isPlaceName(_ phrase: String) -> Bool { names.contains(phrase) }
}

private func coffee(_ id: AssetID) -> FeatureRecord {
    FeatureRecord(assetID: id, value: .labels([Label(identifier: "coffee", confidence: 0.9)]))
}

/// Fingerprints `[v, 0]`, cutoff 0.5: alice near 0, bob near 10, carol near 20.
@Suite("People search")
struct PeopleSearchTests {
    private func makeStore(_ batch: IndexBatch) async throws -> SQLiteIndexStore {
        let store = SQLiteIndexStore(path: ":memory:", faceCutoff: 0.5)
        try await store.prepare()
        try await store.commit(batch)
        return store
    }

    private func face(_ asset: AssetID, _ slot: Int = 0) -> FaceID {
        FaceID(asset: asset, box: .face(slot: slot))
    }

    @Test("R-08/R-11: a group photo is found by each name, and two names need both people")
    func groupPhoto() async throws {
        let store = try await makeStore(.photos([
            ("both", [.fixture(0), .fixture(10, box: .face(slot: 1))]),
            ("aliceOnly", [.fixture(0.1)]),
            ("bobOnly", [.fixture(10.1)]),
            ("nobody", []),
        ]))
        try await store.nameFace(face("both"), as: "Alice")
        try await store.nameFace(face("both", 1), as: "Bob")
        let engine = SearchEngine(index: store, people: store)

        #expect(Set(try await engine.search(SearchQuery("alice")).map(\.id)) == ["both", "aliceOnly"])
        #expect(Set(try await engine.search(SearchQuery("bob")).map(\.id)) == ["both", "bobOnly"])
        #expect(try await engine.search(SearchQuery("alice bob")).map(\.id) == ["both"])
    }

    @Test("R-10: a name-only query lists that person's photos newest first with probability 1")
    func nameOnly() async throws {
        let store = try await makeStore(.photos([
            ("old", [.fixture(0)]),
            ("mid", [.fixture(0.1)]),
            ("other", [.fixture(10)]),
            ("new", [.fixture(0.2)]),
        ]))
        try await store.nameFace(face("mid"), as: "Darshan")
        let engine = SearchEngine(index: store, people: store)

        let results = try await engine.search(SearchQuery("Darshan"))

        #expect(results.map(\.id) == ["new", "mid", "old"])
        #expect(results.allSatisfy { $0.score == 1 })
        #expect(results.allSatisfy { $0.ranks.keys.contains(.person) })
    }

    @Test("R-09: a name plus content returns only that person's photos, ranked by the content")
    func nameWithContent() async throws {
        var batch = IndexBatch.photos([
            ("withCoffee", [.fixture(0)]),
            ("noCoffee", [.fixture(0.1)]),
            ("strangerCoffee", [.fixture(10)]),
            ("noFace", []),
        ])
        batch.features += [coffee("withCoffee"), coffee("strangerCoffee"), coffee("noFace")]
        let store = try await makeStore(batch)
        try await store.nameFace(face("withCoffee"), as: "darshan")
        let engine = SearchEngine(index: store, people: store)

        let results = try await engine.search(SearchQuery("darshan having coffee at cafe"))

        #expect(results.first?.id == "withCoffee")
        #expect(Set(results.map(\.id)).isSubset(of: ["withCoffee", "noCoffee"]))
        #expect(results.allSatisfy { (0...1).contains($0.score) })
    }

    @Test("R-09: a person whose name is also a place wins over the place")
    func personBeatsPlace() async throws {
        let store = try await makeStore(.photos(
            [("friend", [.fixture(0)]), ("trip", [])],
            placeTerms: ["trip": ["Paris", "France"]]
        ))
        try await store.nameFace(face("friend"), as: "paris")
        let engine = SearchEngine(index: store, placeVocabulary: Places(names: ["paris", "france"]), people: store)

        #expect(try await engine.search(SearchQuery("paris")).map(\.id) == ["friend"])
    }

    @Test("R-09: a word that is no known person is searched as today")
    func unknownNameFallsBack() async throws {
        var batch = IndexBatch.photos([("friend", [.fixture(0)]), ("sign", [])])
        batch.features.append(FeatureRecord(assetID: "sign", value: .text(RecognizedText(lines: [.init(content: "bob's diner", confidence: 1, boundingBox: .unit)]))))
        let store = try await makeStore(batch)
        try await store.nameFace(face("friend"), as: "alice")
        let engine = SearchEngine(index: store, people: store)

        let results = try await engine.search(SearchQuery("bob"))

        #expect(results.map(\.id) == ["sign"])
        #expect(!results.contains { $0.ranks.keys.contains(.person) })
    }

    @Test("R-17: naming and unnaming take effect on the next search of the same engine")
    func namesReadPerSearch() async throws {
        let store = try await makeStore(.photos([("p", [.fixture(20)]), ("q", [.fixture(20.2)])]))
        let engine = SearchEngine(index: store, people: store)
        #expect(try await engine.search(SearchQuery("carol")).isEmpty)

        try await store.nameFace(face("p"), as: "Carol")
        #expect(try await engine.search(SearchQuery("carol")).map(\.id) == ["q", "p"])

        try await store.unnameFace(face("p"))
        #expect(try await engine.search(SearchQuery("carol")).isEmpty)
    }
}
