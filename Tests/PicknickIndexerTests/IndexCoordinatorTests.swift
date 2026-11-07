import Foundation
import PicknickCore
import PicknickIndexer
import PicknickStore
import PicknickTestSupport
import Testing

private struct StubPlaceNaming: PlaceNaming {
    func placeTerms(for coordinate: Coordinate) -> [String] {
        coordinate.latitude > 0 ? ["Lisbon", "Portugal"] : []
    }
}

@Suite("Index coordinator")
struct IndexCoordinatorTests {
    private func makeCoordinator(
        library: InMemoryPhotoLibrary,
        extractors: [any FeatureExtractor],
        imageLoader: StubImageLoader = StubImageLoader(),
        configuration: IndexerConfiguration = IndexerConfiguration(batchSize: 4, metadataChunkSize: 4, maxConcurrentAssets: 2),
        throttle: any ThrottlePolicy = UnthrottledPolicy()
    ) async throws -> (IndexCoordinator, SQLiteIndexStore) {
        let store = SQLiteIndexStore.inMemory()
        let coordinator = IndexCoordinator(
            library: library,
            store: store,
            imageLoader: imageLoader,
            extractors: extractors,
            throttle: throttle,
            configuration: configuration
        )
        return (coordinator, store)
    }

    @Test("A first run indexes the whole library")
    func initialRun() async throws {
        let library = InMemoryPhotoLibrary(assets: AssetMetadata.sequence(count: 10))
        let embedder = StubExtractor.embedding()
        let (coordinator, store) = try await makeCoordinator(library: library, extractors: [embedder])

        let progress = try await coordinator.run()

        #expect(progress.statistics.totalAssets == 10)
        #expect(progress.statistics.completedByStage[.embedding] == 10)
        #expect(embedder.processedAssets.count == 10)
        #expect(try await store.pendingWork([embedder.requirement], retryFailuresBefore: .distantFuture, limit: 50).isEmpty)
    }

    @Test("A second run with no library change does nothing")
    func idempotentRun() async throws {
        let library = InMemoryPhotoLibrary(assets: AssetMetadata.sequence(count: 5))
        let embedder = StubExtractor.embedding()
        let (coordinator, _) = try await makeCoordinator(library: library, extractors: [embedder])

        try await coordinator.run()
        let processedAfterFirst = embedder.processedAssets.count
        let second = try await coordinator.run()

        #expect(processedAfterFirst == 5)
        #expect(embedder.processedAssets.count == 5)
        #expect(second.processedThisRun == 0)
    }

    @Test("A new photo is picked up on the next run")
    func picksUpInsertions() async throws {
        let library = InMemoryPhotoLibrary(assets: AssetMetadata.sequence(count: 3))
        let embedder = StubExtractor.embedding()
        let (coordinator, _) = try await makeCoordinator(library: library, extractors: [embedder])

        try await coordinator.run()
        await library.insert(.fixture(id: "fresh", createdAt: .now))
        let progress = try await coordinator.run()

        #expect(progress.statistics.totalAssets == 4)
        #expect(embedder.processedAssets.contains("fresh"))
    }

    @Test("A deleted photo is dropped from the index")
    func picksUpDeletions() async throws {
        let library = InMemoryPhotoLibrary(assets: AssetMetadata.sequence(count: 3))
        let (coordinator, store) = try await makeCoordinator(
            library: library,
            extractors: [StubExtractor.embedding()]
        )

        try await coordinator.run()
        await library.remove("asset-1")
        try await coordinator.synchronize()

        #expect(try await store.metadata(for: ["asset-1"]).isEmpty)
        #expect(try await store.fingerprints().count == 2)
    }

    @Test("An edited photo has its metadata rewritten")
    func picksUpEdits() async throws {
        let library = InMemoryPhotoLibrary(assets: [.fixture(id: "a")])
        let (coordinator, store) = try await makeCoordinator(
            library: library,
            extractors: [StubExtractor.embedding()]
        )

        try await coordinator.run()
        let editedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        await library.touch("a", modifiedAt: editedAt)
        let delta = try await coordinator.synchronize()

        #expect(delta.updated == ["a"])
        #expect(try await store.metadata(for: ["a"]).first?.modifiedAt == editedAt)
    }

    @Test("A gated stage is settled without running")
    func gatedStageIsSettled() async throws {
        let library = InMemoryPhotoLibrary(assets: [
            .fixture(id: "photo"),
            .fixture(id: "shot", traits: [.screenshot]),
        ])
        let recognizer = StubExtractor.screenshotText("BOARDING PASS")
        let (coordinator, store) = try await makeCoordinator(library: library, extractors: [recognizer])

        try await coordinator.run()

        #expect(recognizer.processedAssets == ["shot"])
        #expect(try await store.pendingWork([recognizer.requirement], retryFailuresBefore: .distantFuture, limit: 10).isEmpty)
    }

    @Test("Stages sharing a resolution decode one image between them")
    func sharesDecodePerResolution() async throws {
        let library = InMemoryPhotoLibrary(assets: [.fixture(id: "a", traits: [.screenshot])])
        let loader = StubImageLoader()
        let (coordinator, _) = try await makeCoordinator(
            library: library,
            extractors: [
                StubExtractor.embedding(),
                StubExtractor.labels(["sign"]),
                StubExtractor.screenshotText("EXIT"),
            ],
            imageLoader: loader
        )

        try await coordinator.run()

        let sizes = await loader.requests.map(\.maxPixelSize)
        #expect(sizes.sorted() == [512, 1024])
    }

    @Test("Indexing never reaches for iCloud on its own")
    func neverRequestsNetwork() async throws {
        let library = InMemoryPhotoLibrary(assets: AssetMetadata.sequence(count: 3))
        let loader = StubImageLoader()
        let (coordinator, _) = try await makeCoordinator(
            library: library,
            extractors: [StubExtractor.embedding()],
            imageLoader: loader
        )

        try await coordinator.run()

        let requests = await loader.requests
        #expect(requests.allSatisfy { !$0.allowsNetworkAccess })
    }

    @Test("A cloud-only asset stays queued instead of failing permanently")
    func cloudOnlyAssetIsRetried() async throws {
        let library = InMemoryPhotoLibrary(assets: [.fixture(id: "a")])
        let loader = StubImageLoader()
        await loader.failAll(for: "a", with: .assetUnavailableLocally("a"))
        let embedder = StubExtractor.embedding()
        let (coordinator, store) = try await makeCoordinator(
            library: library,
            extractors: [embedder],
            imageLoader: loader
        )

        try await coordinator.run()

        let pending = try await store.pendingWork([embedder.requirement], retryFailuresBefore: .distantFuture, limit: 10)
        #expect(pending.first?.stages == [.embedding])
    }

    @Test("An undecodable asset stops re-entering the queue")
    func corruptAssetIsAbandoned() async throws {
        let library = InMemoryPhotoLibrary(assets: [.fixture(id: "a")])
        let loader = StubImageLoader()
        await loader.failAll(for: "a", with: .imageDecodingFailed("a"))
        let embedder = StubExtractor.embedding()
        let (coordinator, store) = try await makeCoordinator(
            library: library,
            extractors: [embedder],
            imageLoader: loader
        )

        try await coordinator.run()

        #expect(try await store.pendingWork([embedder.requirement], retryFailuresBefore: .distantFuture, limit: 10).isEmpty)
        let statistics = try await store.statistics(for: [embedder.requirement])
        #expect(statistics.permanentFailures == 1)
    }

    @Test("One failing stage does not block the others")
    func failureIsolatedToItsStage() async throws {
        let library = InMemoryPhotoLibrary(assets: [.fixture(id: "a")])
        let failing = StubExtractor(stage: .labels, produce: { _ in
            throw PicknickError.extractionFailed(stage: .labels, message: "model missing")
        })
        let embedder = StubExtractor.embedding()
        let (coordinator, store) = try await makeCoordinator(
            library: library,
            extractors: [embedder, failing]
        )

        try await coordinator.run()

        let statistics = try await store.statistics(for: [embedder.requirement, failing.requirement])
        #expect(statistics.completedByStage[.embedding] == 1)
        #expect(statistics.completedByStage[.labels] == 0)
    }

    @Test("Raising a version re-indexes that stage only")
    func versionBumpReindexes() async throws {
        let library = InMemoryPhotoLibrary(assets: AssetMetadata.sequence(count: 3))
        let store = SQLiteIndexStore.inMemory()
        let loader = StubImageLoader()
        let configuration = IndexerConfiguration(batchSize: 4, metadataChunkSize: 4, maxConcurrentAssets: 1)

        let first = StubExtractor.embedding(version: 1)
        try await IndexCoordinator(
            library: library, store: store, imageLoader: loader,
            extractors: [first], throttle: UnthrottledPolicy(), configuration: configuration
        ).run()

        let second = StubExtractor.embedding(version: 2)
        try await IndexCoordinator(
            library: library, store: store, imageLoader: loader,
            extractors: [second], throttle: UnthrottledPolicy(), configuration: configuration
        ).run()

        #expect(first.processedAssets.count == 3)
        #expect(second.processedAssets.count == 3)
    }

    @Test("A denied library is reported rather than silently skipped")
    func requiresAuthorization() async throws {
        let library = InMemoryPhotoLibrary(assets: [], authorization: .denied)
        let (coordinator, _) = try await makeCoordinator(library: library, extractors: [])

        await #expect(throws: PicknickError.self) {
            try await coordinator.synchronize()
        }
    }

    @Test("A limited library indexes the assets it can see")
    func supportsLimitedAccess() async throws {
        let library = InMemoryPhotoLibrary(
            assets: AssetMetadata.sequence(count: 2),
            authorization: .limited
        )
        let (coordinator, _) = try await makeCoordinator(
            library: library,
            extractors: [StubExtractor.embedding()]
        )

        let progress = try await coordinator.run()
        #expect(progress.statistics.totalAssets == 2)
    }

    @Test("A throttled device pauses instead of working")
    func throttlePauses() async throws {
        struct Blocked: ThrottlePolicy {
            func permitsWork() -> Bool { false }
        }

        let library = InMemoryPhotoLibrary(assets: AssetMetadata.sequence(count: 3))
        let embedder = StubExtractor.embedding()
        let (coordinator, _) = try await makeCoordinator(
            library: library,
            extractors: [embedder],
            throttle: Blocked()
        )

        let progress = try await coordinator.run()

        #expect(progress.phase == .paused)
        #expect(embedder.processedAssets.isEmpty)
        // Metadata still landed, so the library is filterable by date already.
        #expect(progress.statistics.totalAssets == 3)
    }

    @Test("Metadata is read in chunks rather than one call per asset")
    func readsMetadataInChunks() async throws {
        let library = InMemoryPhotoLibrary(assets: AssetMetadata.sequence(count: 10))
        let (coordinator, _) = try await makeCoordinator(
            library: library,
            extractors: [],
            configuration: IndexerConfiguration(batchSize: 4, metadataChunkSize: 4, maxConcurrentAssets: 1)
        )

        try await coordinator.synchronize()

        let requests = await library.metadataRequests
        #expect(requests.count == 3)
        #expect(requests.map(\.count) == [4, 4, 2])
    }

    @Test("Synchronizing stores place names for located assets only")
    func storesPlaceTerms() async throws {
        let library = InMemoryPhotoLibrary(assets: [
            .fixture(id: "located", coordinate: Coordinate(latitude: 38.72, longitude: -9.14)),
            .fixture(id: "unlocated"),
            .fixture(id: "unnamed", coordinate: Coordinate(latitude: -10, longitude: 0)),
        ])
        let store = SQLiteIndexStore.inMemory()
        let coordinator = IndexCoordinator(
            library: library,
            store: store,
            imageLoader: StubImageLoader(),
            extractors: [],
            throttle: UnthrottledPolicy(),
            placeNaming: StubPlaceNaming()
        )

        try await coordinator.synchronize()

        #expect(try await store.placeMatches(["lisbon"], filter: .none, limit: 10).map(\.id) == ["located"])
        #expect(try await store.placeMatches(["portugal"], filter: .none, limit: 10).map(\.id) == ["located"])
        #expect(try await store.assets(matching: .none, limit: nil).count == 3)
    }
}
