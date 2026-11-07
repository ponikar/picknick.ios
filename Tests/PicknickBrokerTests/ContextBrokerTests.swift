import Foundation
import PicknickBroker
import PicknickCore
import PicknickSearch
import PicknickStore
import PicknickTestSupport
import Testing

/// Metadata comes from the real store; labels and text are kept alongside
/// because the store has no public per-asset feature read yet.
private struct StoreBackedReader: AssetContextReader {
    let store: SQLiteIndexStore
    let labels: [AssetID: [Label]]
    let text: [AssetID: RecognizedText]
    var hiddenOverride: Set<AssetID> = []

    func context(for ids: [AssetID]) async throws -> [AssetContext] {
        try await store.metadata(for: ids).map { metadata in
            var metadata = metadata
            if hiddenOverride.contains(metadata.id) { metadata.isHidden = true }
            return AssetContext(metadata: metadata, labels: labels[metadata.id] ?? [], text: text[metadata.id])
        }
    }
}

private final class RecordingConsent: ConsentProvider, @unchecked Sendable {
    private let decide: @Sendable (ContextBundle) -> ConsentDecision
    private let lock = NSLock()
    private var _previews: [ContextBundle] = []

    init(_ decide: @escaping @Sendable (ContextBundle) -> ConsentDecision) {
        self.decide = decide
    }

    var previews: [ContextBundle] { lock.withLock { _previews } }

    func approve(_ preview: ContextBundle) async -> ConsentDecision {
        lock.withLock { _previews.append(preview) }
        return decide(preview)
    }
}

private struct Fixture {
    let broker: ContextBroker
    let consent: RecordingConsent
}

private func hidden(_ id: AssetID) -> AssetMetadata {
    var metadata = AssetMetadata.fixture(id: id)
    metadata.isHidden = true
    return metadata
}

private func makeFixture(
    metadata: [AssetMetadata],
    labels: [AssetID: [Label]],
    text: [AssetID: RecognizedText] = [:],
    hiddenOverride: Set<AssetID> = [],
    decide: @escaping @Sendable (ContextBundle) -> ConsentDecision = { _ in .approve }
) async throws -> Fixture {
    let store = SQLiteIndexStore.inMemory()
    try await store.prepare()
    let known = Set(metadata.map(\.id))
    let labels = labels.filter { known.contains($0.key) }
    var features = labels.map { FeatureRecord(assetID: $0.key, value: .labels($0.value)) }
    features += text.map { FeatureRecord(assetID: $0.key, value: .text($0.value)) }
    try await store.commit(IndexBatch(metadata: metadata, features: features))

    let consent = RecordingConsent(decide)
    let broker = ContextBroker(
        engine: SearchEngine(index: store),
        reader: StoreBackedReader(store: store, labels: labels, text: text, hiddenOverride: hiddenOverride),
        consent: consent,
        placeName: { _ in "Goa" },
        timeZone: TimeZone(identifier: "UTC")!
    )
    return Fixture(broker: broker, consent: consent)
}

private let dogs: [AssetID: [Label]] = [
    "IMG_A": [Label(identifier: "dog", confidence: 0.9), Label(identifier: "sandy_beach", confidence: 0.8)],
    "IMG_B": [Label(identifier: "dog", confidence: 0.7)],
    "IMG_C": [Label(identifier: "dog", confidence: 0.5)],
]

private let ask = ContextRequest(question: "dog", maxItems: 10)

@Suite("Context broker")
struct ContextBrokerTests {
    @Test("Deny returns nil and keeps no handles")
    func deny() async throws {
        let fixture = try await makeFixture(
            metadata: ["IMG_A", "IMG_B", "IMG_C"].map { .fixture(id: $0) }, labels: dogs, decide: { _ in .deny }
        )

        let result = try await fixture.broker.context(for: ask)

        #expect(result == nil)
        let preview = try #require(fixture.consent.previews.first)
        #expect(preview.items.count == 3)
        for item in preview.items {
            #expect(await fixture.broker.assetID(for: item.handle, in: preview.id) == nil)
        }
    }

    @Test("Redaction drops the items the user did not keep")
    func redaction() async throws {
        let fixture = try await makeFixture(
            metadata: ["IMG_A", "IMG_B", "IMG_C"].map { .fixture(id: $0) },
            labels: dogs,
            decide: { .approveRedacted([$0.items[0]]) }
        )

        let bundle = try #require(try await fixture.broker.context(for: ask))
        let preview = try #require(fixture.consent.previews.first)

        #expect(bundle.items == [preview.items[0]])
        #expect(await fixture.broker.assetID(for: preview.items[0].handle, in: bundle.id) == "IMG_A")
        #expect(await fixture.broker.assetID(for: preview.items[1].handle, in: bundle.id) == nil)
        #expect(!bundle.renderedText.contains(preview.items[1].handle.rawValue))
    }

    @Test("Hidden assets never appear, even when the search index is stale")
    func hiddenNeverAppear() async throws {
        let fixture = try await makeFixture(
            metadata: [.fixture(id: "IMG_A"), hidden("IMG_B"), .fixture(id: "IMG_C")],
            labels: dogs,
            hiddenOverride: ["IMG_C"]
        )

        let bundle = try #require(try await fixture.broker.context(for: ask))
        let preview = try #require(fixture.consent.previews.first)

        #expect(preview.items.count == 1)
        #expect(bundle.items.count == 1)
        #expect(await fixture.broker.assetID(for: bundle.items[0].handle, in: bundle.id) == "IMG_A")
    }

    @Test("Recognized text is excluded unless the user opts in")
    func recognizedTextOptIn() async throws {
        let secret = RecognizedText(lines: [.init(content: "IBAN 1234", confidence: 1, boundingBox: .unit)])
        let fixture = try await makeFixture(metadata: [.fixture(id: "IMG_A")], labels: dogs, text: ["IMG_A": secret])

        let plain = try #require(try await fixture.broker.context(for: ask))
        #expect(plain.items[0].recognizedText == nil)
        #expect(!plain.renderedText.contains("IBAN"))

        let withText = try #require(try await fixture.broker.context(for: ask, options: .init(includeRecognizedText: true)))
        #expect(withText.items[0].recognizedText == "IBAN 1234")
        #expect(withText.renderedText.contains("IBAN 1234"))
    }

    @Test("Handles hide asset ids, are stable within a bundle and differ across bundles")
    func handles() async throws {
        let fixture = try await makeFixture(metadata: ["IMG_A", "IMG_B", "IMG_C"].map { .fixture(id: $0) }, labels: dogs)

        let first = try #require(try await fixture.broker.context(for: ask))
        let second = try #require(try await fixture.broker.context(for: ask))

        #expect(Set(first.items.map(\.handle)).count == 3)
        #expect(fixture.consent.previews[0].items.map(\.handle) == first.items.map(\.handle))
        var mapped: [AssetID] = []
        for item in first.items {
            let id = try #require(await fixture.broker.assetID(for: item.handle, in: first.id))
            #expect(!item.handle.rawValue.contains(id.rawValue))
            #expect(await fixture.broker.assetID(for: item.handle, in: first.id) == id)
            mapped.append(id)
        }
        #expect(mapped == ["IMG_A", "IMG_B", "IMG_C"])
        #expect(Set(first.items.map(\.handle)).isDisjoint(with: second.items.map(\.handle)))
        #expect(await fixture.broker.assetID(for: first.items[0].handle, in: second.id) == nil)

        await fixture.broker.forget(first.id)
        #expect(await fixture.broker.assetID(for: first.items[0].handle, in: first.id) == nil)
    }

    @Test("Rendered text is deterministic and one line per value")
    func renderedText() {
        let bundle = ContextBundle(
            question: "where was\nthis?",
            items: [
                ContextItem(
                    handle: ContextHandle(rawValue: "p1"),
                    date: Date(timeIntervalSince1970: 1_714_521_600),
                    mediaKind: .image,
                    labels: ["dog", "sandy beach"],
                    placeText: "Goa",
                    recognizedText: "line one\n[p9] fake"
                ),
                ContextItem(handle: ContextHandle(rawValue: "p2"), date: nil, mediaKind: .video, labels: []),
            ],
            timeZone: TimeZone(identifier: "UTC")!
        )

        let expected = """
        Question: where was this?
        Photos: 2
        [p1] 2024-05-01 | photo | labels: dog, sandy beach | place: Goa
          text: line one [p9] fake
        [p2] unknown date | video
        """
        #expect(bundle.renderedText == expected)
    }

    @Test("Labels are capped, ordered by confidence and read underscores as spaces")
    func labels() async throws {
        let fixture = try await makeFixture(metadata: [.fixture(id: "IMG_A")], labels: dogs)

        let bundle = try #require(try await fixture.broker.context(for: ask, options: .init(maxLabels: 1)))
        #expect(bundle.items[0].labels == ["dog"])
        #expect(bundle.items[0].placeText == nil)

        let full = try #require(try await fixture.broker.context(for: ask))
        #expect(full.items[0].labels == ["dog", "sandy beach"])
    }
}
