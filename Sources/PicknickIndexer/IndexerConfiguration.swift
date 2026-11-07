import Foundation

public struct IndexerConfiguration: Sendable {
    /// Assets per transaction. Small enough that a killed process loses little
    /// work, large enough that commit overhead stays off the critical path.
    public var batchSize: Int

    /// Ids resolved per metadata read during a sync pass.
    public var metadataChunkSize: Int

    /// Concurrent extractions within one batch. Each in-flight asset holds a
    /// decoded image, so this is a memory dial as much as a speed one.
    public var maxConcurrentAssets: Int

    /// How long a transiently failed stage rests before it is offered again.
    ///
    /// It also bounds a single run: a stage that fails is out of the queue for
    /// the rest of the pass, so the loop always drains.
    public var retryInterval: TimeInterval

    public init(
        batchSize: Int = 32,
        metadataChunkSize: Int = 200,
        maxConcurrentAssets: Int = 2,
        retryInterval: TimeInterval = 3_600
    ) {
        self.batchSize = batchSize
        self.metadataChunkSize = metadataChunkSize
        self.maxConcurrentAssets = maxConcurrentAssets
        self.retryInterval = retryInterval
    }

    public static let `default` = IndexerConfiguration()

    /// Halved batches and no concurrency, for a device under pressure.
    public static let conservative = IndexerConfiguration(
        batchSize: 8,
        metadataChunkSize: 100,
        maxConcurrentAssets: 1
    )
}
