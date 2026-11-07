import Foundation
import PicknickCore

/// Owns the indexing loop: scan the library, write what is new, then drain the
/// outstanding stages a batch at a time.
///
/// It holds no framework of its own. Everything it touches arrives as a
/// protocol, which is what lets the whole loop run against fakes.
public actor IndexCoordinator {
    private let library: any PhotoLibrary
    private let store: any IndexStore
    private let processor: AssetProcessor
    private let extractors: [any FeatureExtractor]
    private let throttle: any ThrottlePolicy
    private let placeNaming: (any PlaceNaming)?
    private let configuration: IndexerConfiguration

    private var progressContinuations: [UUID: AsyncStream<IndexProgress>.Continuation] = [:]
    private var latest = IndexProgress()

    /// The metadata stage has no extractor; the sync pass fulfils it directly.
    private static let metadataVersion = 1

    public init(
        library: any PhotoLibrary,
        store: any IndexStore,
        imageLoader: any ImageLoader,
        extractors: [any FeatureExtractor],
        throttle: any ThrottlePolicy = DeviceThrottlePolicy(),
        placeNaming: (any PlaceNaming)? = nil,
        configuration: IndexerConfiguration = .default
    ) {
        self.library = library
        self.store = store
        self.extractors = extractors
        self.processor = AssetProcessor(imageLoader: imageLoader, extractors: extractors)
        self.throttle = throttle
        self.placeNaming = placeNaming
        self.configuration = configuration
    }

    public var progress: AsyncStream<IndexProgress> {
        let id = UUID()
        let snapshot = latest
        return AsyncStream { continuation in
            continuation.yield(snapshot)
            progressContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    /// Brings the index level with the library, then works the queue until it
    /// empties, the throttle withholds permission, or the task is cancelled.
    @discardableResult
    public func run() async throws -> IndexProgress {
        try await store.prepare()

        try await synchronize()

        var processed = 0
        while !Task.isCancelled {
            guard throttle.permitsWork() else {
                await publish(phase: .paused, processed: processed)
                break
            }

            let outcome = try await processNextBatch()
            // A pass that settled nothing would settle nothing next time
            // either; stopping here is what keeps the loop finite.
            guard outcome.assetsConsidered > 0, outcome.madeProgress else { break }

            processed += outcome.assetsConsidered
            await publish(phase: .extracting, processed: processed)
        }

        if !Task.isCancelled, latest.phase != .paused {
            await publish(phase: .idle, processed: processed)
        }
        return latest
    }

    /// Diffs the library against the index and writes metadata for anything new
    /// or changed, deleting what is gone.
    ///
    /// This is the entire resync strategy: one scan, one diff, no change tokens
    /// and no background bookkeeping to fall out of date.
    @discardableResult
    public func synchronize() async throws -> LibraryDelta {
        try await store.prepare()

        let authorization = await library.authorization
        guard authorization.allowsReading else {
            throw PicknickError.notAuthorized(authorization)
        }

        await publish(phase: .scanning, processed: latest.processedThisRun)

        let delta = LibraryDiff.compute(
            library: try await library.fingerprints(),
            index: try await store.fingerprints()
        )

        guard !delta.isEmpty else { return delta }

        await publish(phase: .writingMetadata, processed: latest.processedThisRun)

        for chunk in delta.removed.chunked(into: configuration.metadataChunkSize) {
            try await store.commit(IndexBatch(removals: chunk))
        }

        for chunk in delta.needingMetadata.chunked(into: configuration.metadataChunkSize) {
            try Task.checkCancellation()
            let metadata = try await library.metadata(for: chunk)
            try await store.commit(
                IndexBatch(
                    metadata: metadata,
                    completions: metadata.map {
                        StageCompletion(
                            assetID: $0.id,
                            stage: .metadata,
                            version: Self.metadataVersion
                        )
                    },
                    placeTerms: placeTerms(for: metadata)
                )
            )
        }

        return delta
    }

    /// Runs one batch of outstanding stages.
    public func processNextBatch() async throws -> BatchOutcome {
        let pending = try await store.pendingWork(
            extractors.map(\.requirement),
            retryFailuresBefore: Date.now.addingTimeInterval(-configuration.retryInterval),
            limit: configuration.batchSize
        )
        guard !pending.isEmpty else { return .empty }

        var batch = IndexBatch()
        for group in pending.chunked(into: configuration.maxConcurrentAssets) {
            try Task.checkCancellation()

            let results = await withTaskGroup(of: IndexBatch.self) { tasks in
                for work in group {
                    tasks.addTask { [processor] in await processor.process(work) }
                }
                var collected: [IndexBatch] = []
                for await result in tasks { collected.append(result) }
                return collected
            }

            for result in results { batch.merge(result) }
        }

        try await store.commit(batch)

        return BatchOutcome(
            assetsConsidered: pending.count,
            stagesCompleted: batch.completions.count,
            stagesFailed: batch.failures.count
        )
    }

    public func statistics() async throws -> IndexStatistics {
        try await store.prepare()
        return try await store.statistics(for: requirements)
    }

    private var requirements: [StageRequirement] {
        [StageRequirement(stage: .metadata, version: Self.metadataVersion)]
            + extractors.map(\.requirement)
    }

    private func placeTerms(for metadata: [AssetMetadata]) -> [AssetID: [String]] {
        guard let placeNaming else { return [:] }
        var terms: [AssetID: [String]] = [:]
        for asset in metadata {
            guard let coordinate = asset.coordinate, coordinate.isValid else { continue }
            let names = placeNaming.placeTerms(for: coordinate)
            if !names.isEmpty { terms[asset.id] = names }
        }
        return terms
    }

    private func publish(phase: IndexPhase, processed: Int) async {
        let statistics = (try? await store.statistics(for: requirements)) ?? latest.statistics
        latest = IndexProgress(
            phase: phase,
            processedThisRun: processed,
            statistics: statistics
        )
        for continuation in progressContinuations.values {
            continuation.yield(latest)
        }
    }

    private func removeContinuation(_ id: UUID) {
        progressContinuations[id] = nil
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, count > size else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
