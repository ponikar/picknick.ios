import Foundation

/// An asset together with the stages still owed for it.
///
/// Carrying the missing stages with the asset is what keeps the coordinator
/// from re-running work that already landed: without it, picking up an asset
/// for one outstanding stage would redo every other stage too.
public struct PendingWork: Hashable, Sendable {
    public let metadata: AssetMetadata
    public let stages: Set<IndexStage>

    public init(metadata: AssetMetadata, stages: Set<IndexStage>) {
        self.metadata = metadata
        self.stages = stages
    }

    public var id: AssetID { metadata.id }
}
