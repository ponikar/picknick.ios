import CoreGraphics
import Foundation
import PicknickCore

/// Each adapter below wraps a real implementation and prints the call.
///
/// They exist to make the trace readable, but they are also the clearest
/// evidence that the seams are real: nothing in the indexer changes to
/// accommodate them, because they satisfy the same protocols.

struct TracingPhotoLibrary: PhotoLibrary {
    let wrapped: any PhotoLibrary

    var authorization: LibraryAuthorization {
        get async { await wrapped.authorization }
    }

    @discardableResult
    func requestAuthorization() async -> LibraryAuthorization {
        await wrapped.requestAuthorization()
    }

    func fingerprints() async throws -> [AssetID: AssetFingerprint] {
        let result = try await wrapped.fingerprints()
        Log.call("library.fingerprints()", "\(result.count) assets", seam: "PhotoLibrary")
        return result
    }

    func metadata(for ids: [AssetID]) async throws -> [AssetMetadata] {
        let result = try await wrapped.metadata(for: ids)
        Log.call(
            "library.metadata(\(ids.count) \(plural(ids.count, "id")))",
            "\(result.count) \(plural(result.count, "record"))",
            seam: "PhotoLibrary"
        )
        return result
    }

    func changes() -> AsyncStream<Void> { wrapped.changes() }
}

struct TracingIndexStore: IndexStore {
    let wrapped: any IndexStore

    func prepare() async throws {
        try await wrapped.prepare()
    }

    func fingerprints() async throws -> [AssetID: AssetFingerprint] {
        let result = try await wrapped.fingerprints()
        Log.call("store.fingerprints()", "\(result.count) assets", seam: "IndexStore")
        return result
    }

    func commit(_ batch: IndexBatch) async throws {
        try await wrapped.commit(batch)
        Log.call("store.commit(\(summary(of: batch)))", "one transaction", seam: "IndexStore")
    }

    func pendingWork(
        _ requirements: [StageRequirement],
        retryFailuresBefore: Date,
        limit: Int
    ) async throws -> [PendingWork] {
        let result = try await wrapped.pendingWork(
            requirements,
            retryFailuresBefore: retryFailuresBefore,
            limit: limit
        )
        let owed = Set(result.flatMap(\.stages)).sorted().map(\.rawValue).joined(separator: "+")
        Log.call(
            "store.pendingWork(limit: \(limit))",
            result.isEmpty
                ? "nothing owed"
                : "\(result.count) \(plural(result.count, "asset")) owing \(owed)",
            seam: "IndexStore"
        )
        return result
    }

    func metadata(for ids: [AssetID]) async throws -> [AssetMetadata] {
        try await wrapped.metadata(for: ids)
    }

    func statistics(for requirements: [StageRequirement]) async throws -> IndexStatistics {
        try await wrapped.statistics(for: requirements)
    }

    private func summary(of batch: IndexBatch) -> String {
        var parts: [String] = []
        if !batch.metadata.isEmpty { parts.append("metadata \(batch.metadata.count)") }
        if !batch.features.isEmpty { parts.append("features \(batch.features.count)") }
        if !batch.completions.isEmpty { parts.append("done \(batch.completions.count)") }
        if !batch.failures.isEmpty { parts.append("failed \(batch.failures.count)") }
        if !batch.removals.isEmpty { parts.append("removed \(batch.removals.count)") }
        return parts.joined(separator: ", ")
    }
}

struct TracingImageLoader: ImageLoader {
    let wrapped: any ImageLoader

    func loadImage(_ request: ImageRequest) async throws -> CGImage {
        do {
            let image = try await wrapped.loadImage(request)
            Log.call(
                "loader.loadImage(\(request.assetID), \(request.maxPixelSize)px)",
                "decoded",
                seam: "ImageLoader"
            )
            return image
        } catch {
            let permanent = (error as? PicknickError)?.isPermanent ?? false
            Log.call(
                "loader.loadImage(\(request.assetID), \(request.maxPixelSize)px)",
                permanent ? "FAILED, permanent" : "FAILED, will retry",
                seam: "ImageLoader"
            )
            throw error
        }
    }
}


private func plural(_ count: Int, _ noun: String) -> String {
    count == 1 ? noun : noun + "s"
}
