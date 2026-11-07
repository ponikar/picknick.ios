import Foundation

/// The cheap half of an asset: enough to decide whether the index is stale,
/// without loading pixels or full metadata.
///
/// Enumerating fingerprints for an entire library is the only full scan the
/// system performs, so this type stays deliberately small.
public struct AssetFingerprint: Hashable, Sendable, Codable {
    public var modifiedAt: Date?

    public init(modifiedAt: Date?) {
        self.modifiedAt = modifiedAt
    }

    /// Photo libraries store sub-second precision that does not always survive
    /// a round trip through SQLite's REAL column, so comparison is tolerant.
    public func matches(_ other: AssetFingerprint, tolerance: TimeInterval = 0.001) -> Bool {
        switch (modifiedAt, other.modifiedAt) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return abs(lhs.timeIntervalSinceReferenceDate - rhs.timeIntervalSinceReferenceDate) <= tolerance
        default:
            return false
        }
    }
}
