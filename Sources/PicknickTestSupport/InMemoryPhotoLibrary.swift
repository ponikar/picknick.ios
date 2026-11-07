import Foundation
import PicknickCore

/// A photo library held entirely in memory, for tests and previews.
public actor InMemoryPhotoLibrary: PhotoLibrary {
    private var assets: [AssetID: AssetMetadata]
    private var status: LibraryAuthorization
    private var changeContinuation: AsyncStream<Void>.Continuation?

    public private(set) var metadataRequests: [[AssetID]] = []

    public init(
        assets: [AssetMetadata] = [],
        authorization: LibraryAuthorization = .authorized
    ) {
        self.assets = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        self.status = authorization
    }

    public var authorization: LibraryAuthorization {
        get async { status }
    }

    @discardableResult
    public func requestAuthorization() async -> LibraryAuthorization {
        status = status == .notDetermined ? .authorized : status
        return status
    }

    public func fingerprints() async throws -> [AssetID: AssetFingerprint] {
        assets.mapValues(\.fingerprint)
    }

    public func metadata(for ids: [AssetID]) async throws -> [AssetMetadata] {
        metadataRequests.append(ids)
        return ids.compactMap { assets[$0] }
    }

    public nonisolated func changes() -> AsyncStream<Void> {
        AsyncStream { continuation in
            Task { await self.attach(continuation) }
        }
    }

    // MARK: Mutation

    public func insert(_ metadata: AssetMetadata) {
        assets[metadata.id] = metadata
        changeContinuation?.yield(())
    }

    public func remove(_ id: AssetID) {
        assets[id] = nil
        changeContinuation?.yield(())
    }

    public func touch(_ id: AssetID, modifiedAt: Date) {
        assets[id]?.modifiedAt = modifiedAt
        changeContinuation?.yield(())
    }

    public func setAuthorization(_ authorization: LibraryAuthorization) {
        status = authorization
    }

    private func attach(_ continuation: AsyncStream<Void>.Continuation) {
        changeContinuation = continuation
    }
}
