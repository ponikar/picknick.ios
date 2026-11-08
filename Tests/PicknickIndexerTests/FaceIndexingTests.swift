import Foundation
import PicknickCore
import PicknickIndexer
import PicknickStore
import PicknickTestSupport
import Testing

/// A face extractor that gives each asset one face whose fingerprint is chosen by its id.
private func faceStub(_ fingerprints: [AssetID: Float]) -> StubExtractor {
    StubExtractor(stage: .faces, preferredPixelSize: 1024, produce: { context in
        guard let value = fingerprints[context.metadata.id] else { return .faces([]) }
        return .faces([.fixture(value)])
    })
}

@Suite("Face indexing")
struct FaceIndexingTests {
    private func makeCoordinator(
        library: InMemoryPhotoLibrary,
        extractor: StubExtractor
    ) -> (IndexCoordinator, SQLiteIndexStore) {
        let store = SQLiteIndexStore(path: ":memory:", faceCutoff: 0.5)
        let coordinator = IndexCoordinator(
            library: library,
            store: store,
            imageLoader: StubImageLoader(),
            extractors: [extractor],
            throttle: UnthrottledPolicy(),
            configuration: IndexerConfiguration(batchSize: 4, metadataChunkSize: 4, maxConcurrentAssets: 2)
        )
        return (coordinator, store)
    }

    @Test("R-07: a photo added after naming is named automatically when indexed")
    func newPhotoNamedAutomatically() async throws {
        let library = InMemoryPhotoLibrary(assets: [.fixture(id: "first"), .fixture(id: "stranger")])
        let (coordinator, store) = makeCoordinator(
            library: library,
            extractor: faceStub(["first": 0, "stranger": 10, "later": 0.3])
        )
        try await coordinator.run()
        try await store.nameFace(FaceID(asset: "first", box: .face()), as: "darshan")

        await library.insert(.fixture(id: "later", createdAt: .now))
        try await coordinator.run()

        #expect(Set(try await store.assets(withAll: ["darshan"], filter: .none, limit: nil)) == ["first", "later"])
    }

    @Test("R-02: a photo with no faces completes the face stage and is not re-run")
    func noFacesCompletes() async throws {
        let library = InMemoryPhotoLibrary(assets: [.fixture(id: "empty")])
        let extractor = faceStub([:])
        let (coordinator, store) = makeCoordinator(library: library, extractor: extractor)

        try await coordinator.run()
        try await coordinator.run()

        #expect(extractor.processedAssets == ["empty"])
        #expect(try await store.faceGroups().isEmpty)
        #expect(try await store.statistics(for: [extractor.requirement]).completedByStage[.faces] == 1)
    }

    @Test("R-12: deleting a photo from the library deletes its faces, other names stay")
    func deletionRemovesFaces() async throws {
        let library = InMemoryPhotoLibrary(assets: [.fixture(id: "gone"), .fixture(id: "kept")])
        let (coordinator, store) = makeCoordinator(library: library, extractor: faceStub(["gone": 0, "kept": 0.1]))
        try await coordinator.run()
        try await store.nameFace(FaceID(asset: "kept", box: .face()), as: "darshan")

        await library.remove("gone")
        try await coordinator.synchronize()

        let faces = try await store.faceGroups().flatMap(\.faces)
        #expect(faces.map(\.assetID) == ["kept"])
        #expect(try await store.assets(withAll: ["darshan"], filter: .none, limit: nil) == ["kept"])
    }
}
