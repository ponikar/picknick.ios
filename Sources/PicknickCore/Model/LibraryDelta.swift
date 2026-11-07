import Foundation

/// The difference between the host library and the index, as of one scan.
public struct LibraryDelta: Hashable, Sendable {
    public var inserted: [AssetID]
    public var updated: [AssetID]
    public var removed: [AssetID]

    public init(inserted: [AssetID] = [], updated: [AssetID] = [], removed: [AssetID] = []) {
        self.inserted = inserted
        self.updated = updated
        self.removed = removed
    }

    public var isEmpty: Bool {
        inserted.isEmpty && updated.isEmpty && removed.isEmpty
    }

    public var count: Int {
        inserted.count + updated.count + removed.count
    }

    /// Assets whose metadata must be re-read, newest work first.
    public var needingMetadata: [AssetID] {
        inserted + updated
    }
}
