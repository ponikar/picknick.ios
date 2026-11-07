import Foundation
import PicknickCore
import PicknickIndexer
import PicknickStore
import PicknickTestSupport

/// Runs the indexer over a fake library and prints every call it makes.
///
/// The point is to watch the system work once before reading it: each line is
/// one call across a module boundary, and the right-hand column names the
/// protocol that call went through.
@main
struct Trace {
    static let configuration = IndexerConfiguration(
        batchSize: 2,
        metadataChunkSize: 3,
        maxConcurrentAssets: 1,
        retryInterval: 3_600
    )

    static func main() async throws {
        let library = InMemoryPhotoLibrary(assets: startingLibrary)
        let loader = StubImageLoader()
        let store = SQLiteIndexStore.inMemory()

        // This photo has no local copy, the way an iCloud-optimised asset does
        // not on a real device.
        await loader.failAll(for: "photo-cloud", with: .assetUnavailableLocally("photo-cloud"))

        Log.headline("PICKNICK INDEX TRACE")
        Log.note("4 photos, one of them a screenshot, one of them cloud-only")
        Log.note("3 stages: embedding and labels at 512px, text at 1024px")
        Log.note("text runs on screenshots only; batch size is 2")

        try await firstRun(library: library, loader: loader, store: store)
        try await secondRun(library: library, loader: loader, store: store)
        try await newPhoto(library: library, loader: loader, store: store)
        try await deletedPhoto(library: library, loader: loader, store: store)
        try await versionBump(library: library, loader: loader, store: store)
    }

    // MARK: Steps

    private static func firstRun(
        library: InMemoryPhotoLibrary,
        loader: StubImageLoader,
        store: SQLiteIndexStore
    ) async throws {
        Log.step(1, "First run, empty index")
        Log.note("synchronize(): compare the library against the index")

        let progress = try await coordinator(library, loader, store, embeddingVersion: 1).run()

        Log.note("")
        Log.note("photo-cloud kept its embedding and labels owed, because a")
        Log.note("missing local copy is transient and worth retrying later")
        report(progress)
    }

    private static func secondRun(
        library: InMemoryPhotoLibrary,
        loader: StubImageLoader,
        store: SQLiteIndexStore
    ) async throws {
        Log.step(2, "Second run, nothing changed")

        let progress = try await coordinator(library, loader, store, embeddingVersion: 1).run()

        Log.note("")
        Log.note("the diff found no change, and every stage that could be")
        Log.note("settled already was, so no image was decoded")
        report(progress)
    }

    private static func newPhoto(
        library: InMemoryPhotoLibrary,
        loader: StubImageLoader,
        store: SQLiteIndexStore
    ) async throws {
        Log.step(3, "A photo is taken")

        await library.insert(.fixture(id: "photo-new", createdAt: .now))
        let progress = try await coordinator(library, loader, store, embeddingVersion: 1).run()

        Log.note("")
        Log.note("only the new photo was touched; the diff never looked at pixels")
        report(progress)
    }

    private static func deletedPhoto(
        library: InMemoryPhotoLibrary,
        loader: StubImageLoader,
        store: SQLiteIndexStore
    ) async throws {
        Log.step(4, "A photo is deleted")

        await library.remove("photo-dinner")
        let delta = try await coordinator(library, loader, store, embeddingVersion: 1).synchronize()

        Log.note("")
        Log.note("removed \(delta.removed.count): its labels, vectors and text went with it")
    }

    private static func versionBump(
        library: InMemoryPhotoLibrary,
        loader: StubImageLoader,
        store: SQLiteIndexStore
    ) async throws {
        Log.step(5, "The embedding model is upgraded")
        Log.note("the extractor's version goes from 1 to 2; nothing else changes")
        Log.note("")

        let progress = try await coordinator(library, loader, store, embeddingVersion: 2).run()

        Log.note("")
        Log.note("only embedding re-ran; labels and text stayed at version 1")
        Log.note("a model upgrade is a background pass, not a rebuild")
        report(progress)
    }

    // MARK: Wiring

    private static func coordinator(
        _ library: InMemoryPhotoLibrary,
        _ loader: StubImageLoader,
        _ store: SQLiteIndexStore,
        embeddingVersion: Int
    ) -> IndexCoordinator {
        IndexCoordinator(
            library: TracingPhotoLibrary(wrapped: library),
            store: TracingIndexStore(wrapped: store),
            imageLoader: TracingImageLoader(wrapped: loader),
            extractors: [
                StubExtractor.embedding(version: embeddingVersion),
                StubExtractor.labels(["beach", "sunset"]),
                StubExtractor.screenshotText("TOTAL 42.00"),
            ],
            throttle: UnthrottledPolicy(),
            configuration: configuration
        )
    }

    private static var startingLibrary: [AssetMetadata] {
        [
            .fixture(id: "photo-beach", createdAt: day(0)),
            .fixture(id: "photo-dinner", createdAt: day(1)),
            .fixture(id: "shot-receipt", createdAt: day(2), traits: [.screenshot]),
            .fixture(id: "photo-cloud", createdAt: day(3)),
        ]
    }

    private static func day(_ offset: Int) -> Date {
        Date(timeIntervalSinceReferenceDate: 780_000_000 + Double(offset) * 86_400)
    }

    private static func report(_ progress: IndexProgress) {
        let statistics = progress.statistics
        let stages = IndexStage.allCases.compactMap { stage -> String? in
            guard let done = statistics.completedByStage[stage] else { return nil }
            return "\(stage.rawValue) \(done)/\(statistics.totalAssets)"
        }
        Log.note("")
        Log.note("INDEX NOW: " + stages.joined(separator: "   "))
    }
}
