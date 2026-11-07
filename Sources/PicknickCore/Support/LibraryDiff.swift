import Foundation

/// Compares two fingerprint maps.
///
/// Keeping the diff pure and free of any framework is what lets the whole
/// resync strategy be tested without a photo library or a database.
public enum LibraryDiff {
    public static func compute(
        library: [AssetID: AssetFingerprint],
        index: [AssetID: AssetFingerprint]
    ) -> LibraryDelta {
        var inserted: [AssetID] = []
        var updated: [AssetID] = []

        for (id, libraryFingerprint) in library {
            guard let indexed = index[id] else {
                inserted.append(id)
                continue
            }
            if !libraryFingerprint.matches(indexed) {
                updated.append(id)
            }
        }

        let removed = index.keys.filter { library[$0] == nil }

        return LibraryDelta(
            inserted: inserted.sorted(by: stableOrder),
            updated: updated.sorted(by: stableOrder),
            removed: removed.sorted(by: stableOrder)
        )
    }

    /// Sorting only to keep the delta deterministic for tests and logs; real
    /// work order is decided by the store, which sorts by capture date.
    private static func stableOrder(_ lhs: AssetID, _ rhs: AssetID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
