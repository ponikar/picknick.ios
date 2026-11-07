import Foundation

/// Durable home for everything derived from the library.
///
/// Implementations own their own atomicity: every method either applies whole
/// or throws without partial effect.
public protocol IndexStore: Sendable {
    func prepare() async throws

    /// Indexed assets as id and modification date, for diffing against the
    /// library's own fingerprints.
    func fingerprints() async throws -> [AssetID: AssetFingerprint]

    func commit(_ batch: IndexBatch) async throws

    /// Assets missing at least one of `requirements`, ordered newest first so
    /// the photos a user is most likely to search for become searchable first.
    ///
    /// A stage is omitted when it carries a permanent failure, or a transient
    /// one recorded at or after `retryFailuresBefore`. Without that cutoff a
    /// stage that keeps failing would be handed back on every pass and the
    /// caller would never drain the queue.
    func pendingWork(
        _ requirements: [StageRequirement],
        retryFailuresBefore: Date,
        limit: Int
    ) async throws -> [PendingWork]

    func metadata(for ids: [AssetID]) async throws -> [AssetMetadata]

    func statistics(for requirements: [StageRequirement]) async throws -> IndexStatistics
}
