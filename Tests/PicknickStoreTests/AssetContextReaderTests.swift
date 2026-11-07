import Foundation
import PicknickCore
import PicknickStore
import PicknickTestSupport
import Testing

@Suite("SQLite asset context reader")
struct AssetContextReaderTests {
    @Test("Returns metadata, labels by confidence and recognized text; skips unknown ids")
    func readsContext() async throws {
        let store = SQLiteIndexStore.inMemory()
        try await store.prepare()
        let line = RecognizedText.Line(content: "open 9-5", confidence: 1, boundingBox: .unit)
        try await store.commit(
            IndexBatch(
                metadata: [.fixture(id: "a"), .fixture(id: "b")],
                features: [
                    FeatureRecord(assetID: "a", value: .labels([
                        Label(identifier: "dog", confidence: 0.4),
                        Label(identifier: "beach", confidence: 0.9),
                    ])),
                    FeatureRecord(assetID: "a", value: .text(RecognizedText(lines: [line]))),
                ]
            )
        )

        let contexts = try await store.context(for: ["a", "b", "missing"])
        let byID = Dictionary(uniqueKeysWithValues: contexts.map { ($0.metadata.id, $0) })

        #expect(contexts.count == 2)
        #expect(byID["a"]?.labels.map(\.identifier) == ["beach", "dog"])
        #expect(byID["a"]?.text?.joined == "open 9-5")
        #expect(byID["b"]?.labels.isEmpty == true)
        #expect(byID["b"]?.text == nil)
    }
}
