import Foundation

/// Stable identity of a photo within the host library.
///
/// On iOS this wraps `PHAsset.localIdentifier`. It is unique per device but is
/// *not* preserved across a restore from backup; re-attaching an index after a
/// restore is deliberately out of scope for v1.
public struct AssetID: Hashable, Sendable, Codable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

extension AssetID: CustomStringConvertible {
    public var description: String { rawValue }
}

extension AssetID: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self.rawValue = value
    }
}
