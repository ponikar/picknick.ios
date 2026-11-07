import Foundation
import PicknickCore
import PicknickStore
import PicknickTestSupport
import Testing

@Suite("SQLite index store")
struct SQLiteIndexStoreTests {
    private func makeStore() async throws -> SQLiteIndexStore {
        let store = SQLiteIndexStore.inMemory()
        try await store.prepare()
        return store
    }

    private let embeddingRequirement = StageRequirement(stage: .embedding, version: 1)
    private let labelRequirement = StageRequirement(stage: .labels, version: 1)

    @Test("Metadata round-trips through storage")
    func metadataRoundTrip() async throws {
        let store = try await makeStore()
        let original = AssetMetadata.fixture(
            id: "a",
            traits: [.screenshot, .highDynamicRange],
            coordinate: Coordinate(latitude: 35.68, longitude: 139.69),
            isFavorite: true
        )

        try await store.commit(IndexBatch(metadata: [original]))
        let stored = try await store.metadata(for: ["a"]).first

        #expect(stored == original)
    }

    @Test("Preparing twice is harmless")
    func idempotentPrepare() async throws {
        let store = try await makeStore()
        try await store.prepare()

        #expect(try await store.fingerprints().isEmpty)
    }

    @Test("Committing the same asset again updates rather than duplicates")
    func upsert() async throws {
        let store = try await makeStore()
        let first = AssetMetadata.fixture(id: "a", isFavorite: false)
        var second = first
        second.isFavorite = true

        try await store.commit(IndexBatch(metadata: [first]))
        try await store.commit(IndexBatch(metadata: [second]))

        let stored = try await store.metadata(for: ["a"])
        #expect(stored.count == 1)
        #expect(stored.first?.isFavorite == true)
    }

    @Test("Removing an asset cascades to its derived rows")
    func removalCascades() async throws {
        let store = try await makeStore()
        let asset = AssetMetadata.fixture(id: "a")

        try await store.commit(
            IndexBatch(
                metadata: [asset],
                features: [
                    FeatureRecord(assetID: "a", value: .labels([Label(identifier: "beach", confidence: 0.9)])),
                    FeatureRecord(assetID: "a", value: .embedding(Embedding(model: "m", values: [1, 0]))),
                ],
                completions: [StageCompletion(assetID: "a", stage: .labels, version: 1)]
            )
        )

        try await store.commit(IndexBatch(removals: ["a"]))

        #expect(try await store.metadata(for: ["a"]).isEmpty)
        #expect(try await store.fingerprints().isEmpty)

        let statistics = try await store.statistics(for: [labelRequirement])
        #expect(statistics.totalAssets == 0)
        #expect(statistics.completedByStage[.labels] == 0)
    }

    @Test("Pending work lists only the stages an asset still owes")
    func pendingStages() async throws {
        let store = try await makeStore()
        try await store.commit(
            IndexBatch(
                metadata: [.fixture(id: "a")],
                completions: [StageCompletion(assetID: "a", stage: .embedding, version: 1)]
            )
        )

        let pending = try await store.pendingWork(
            [embeddingRequirement, labelRequirement],
            retryFailuresBefore: .distantFuture, limit: 10
        )

        #expect(pending.count == 1)
        #expect(pending.first?.stages == [.labels])
    }

    @Test("An asset owing nothing is not returned")
    func fullySatisfied() async throws {
        let store = try await makeStore()
        try await store.commit(
            IndexBatch(
                metadata: [.fixture(id: "a")],
                completions: [
                    StageCompletion(assetID: "a", stage: .embedding, version: 1),
                    StageCompletion(assetID: "a", stage: .labels, version: 1),
                ]
            )
        )

        let pending = try await store.pendingWork([embeddingRequirement, labelRequirement], retryFailuresBefore: .distantFuture, limit: 10)
        #expect(pending.isEmpty)
    }

    @Test("Raising the extractor version re-opens that stage alone")
    func versionBumpReopensStage() async throws {
        let store = try await makeStore()
        try await store.commit(
            IndexBatch(
                metadata: [.fixture(id: "a")],
                completions: [
                    StageCompletion(assetID: "a", stage: .embedding, version: 1),
                    StageCompletion(assetID: "a", stage: .labels, version: 1),
                ]
            )
        )

        let pending = try await store.pendingWork(
            [StageRequirement(stage: .embedding, version: 2), labelRequirement],
            retryFailuresBefore: .distantFuture, limit: 10
        )

        #expect(pending.first?.stages == [.embedding])
    }

    @Test("A permanent failure keeps its stage out of the queue")
    func permanentFailureIsExcluded() async throws {
        let store = try await makeStore()
        try await store.commit(
            IndexBatch(
                metadata: [.fixture(id: "a")],
                failures: [
                    StageFailure(assetID: "a", stage: .embedding, reason: "corrupt", isPermanent: true)
                ]
            )
        )

        let pending = try await store.pendingWork([embeddingRequirement, labelRequirement], retryFailuresBefore: .distantFuture, limit: 10)
        #expect(pending.first?.stages == [.labels])
    }

    @Test("A transient failure leaves the stage queued")
    func transientFailureStaysQueued() async throws {
        let store = try await makeStore()
        try await store.commit(
            IndexBatch(
                metadata: [.fixture(id: "a")],
                failures: [
                    StageFailure(assetID: "a", stage: .embedding, reason: "in cloud", isPermanent: false)
                ]
            )
        )

        let pending = try await store.pendingWork([embeddingRequirement], retryFailuresBefore: .distantFuture, limit: 10)
        #expect(pending.first?.stages == [.embedding])
    }

    @Test("Completing a stage clears its recorded failure")
    func completionClearsFailure() async throws {
        let store = try await makeStore()
        try await store.commit(
            IndexBatch(
                metadata: [.fixture(id: "a")],
                failures: [
                    StageFailure(assetID: "a", stage: .embedding, reason: "in cloud", isPermanent: true)
                ]
            )
        )
        try await store.commit(
            IndexBatch(completions: [StageCompletion(assetID: "a", stage: .embedding, version: 1)])
        )

        let statistics = try await store.statistics(for: [embeddingRequirement])
        #expect(statistics.permanentFailures == 0)
        #expect(statistics.completedByStage[.embedding] == 1)
    }

    @Test("A stage that just failed rests before it is offered again")
    func recentFailureIsSuppressed() async throws {
        let store = try await makeStore()
        try await store.commit(
            IndexBatch(
                metadata: [.fixture(id: "a")],
                failures: [
                    StageFailure(assetID: "a", stage: .embedding, reason: "in cloud", isPermanent: false)
                ]
            )
        )

        let suppressed = try await store.pendingWork(
            [embeddingRequirement],
            retryFailuresBefore: Date.now.addingTimeInterval(-3_600),
            limit: 10
        )
        #expect(suppressed.isEmpty)

        let afterBackoff = try await store.pendingWork(
            [embeddingRequirement],
            retryFailuresBefore: .distantFuture,
            limit: 10
        )
        #expect(afterBackoff.first?.stages == [.embedding])
    }

    @Test("Pending work is ordered newest first")
    func newestFirst() async throws {
        let store = try await makeStore()
        try await store.commit(IndexBatch(metadata: AssetMetadata.sequence(count: 5)))

        let pending = try await store.pendingWork([embeddingRequirement], retryFailuresBefore: .distantFuture, limit: 3)

        #expect(pending.map(\.id) == ["asset-4", "asset-3", "asset-2"])
    }

    @Test("Embeddings survive the Float16 round trip")
    func embeddingPrecision() async throws {
        let store = try await makeStore()
        let values: [Float] = [0.25, -0.5, 0.75, 1.0]

        try await store.commit(
            IndexBatch(
                metadata: [.fixture(id: "a")],
                features: [FeatureRecord(assetID: "a", value: .embedding(Embedding(model: "m", values: values)))]
            )
        )

        let statistics = try await store.statistics(for: [embeddingRequirement])
        #expect(statistics.totalAssets == 1)
    }

    @Test("A failed commit leaves the database untouched")
    func commitIsAtomic() async throws {
        let store = try await makeStore()
        try await store.commit(IndexBatch(metadata: [.fixture(id: "a")]))

        // The feature references an asset that was never inserted, so the
        // foreign key fails and the whole batch must roll back.
        let poisoned = IndexBatch(
            metadata: [.fixture(id: "b")],
            features: [FeatureRecord(assetID: "ghost", value: .labels([Label(identifier: "x", confidence: 1)]))]
        )

        await #expect(throws: (any Error).self) {
            try await store.commit(poisoned)
        }

        #expect(try await store.metadata(for: ["b"]).isEmpty)
        #expect(try await store.metadata(for: ["a"]).count == 1)
    }

    @Test("Statistics report progress per stage")
    func statistics() async throws {
        let store = try await makeStore()
        try await store.commit(
            IndexBatch(
                metadata: AssetMetadata.sequence(count: 4),
                completions: [
                    StageCompletion(assetID: "asset-0", stage: .embedding, version: 1),
                    StageCompletion(assetID: "asset-1", stage: .embedding, version: 1),
                ]
            )
        )

        let statistics = try await store.statistics(for: [embeddingRequirement])

        #expect(statistics.totalAssets == 4)
        #expect(statistics.progress(for: .embedding) == 0.5)
    }

    @Test("Using the store before preparing it fails loudly")
    func requiresPreparation() async throws {
        let store = SQLiteIndexStore.inMemory()

        await #expect(throws: PicknickError.self) {
            _ = try await store.fingerprints()
        }
    }
}
