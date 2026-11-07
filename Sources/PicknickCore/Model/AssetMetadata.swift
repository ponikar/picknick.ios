import Foundation

/// Everything the index knows about a photo before any model runs.
///
/// This is free to read from the host library, so it is written in the first
/// pass and is what makes an asset filterable by date, place and kind long
/// before its embedding exists.
public struct AssetMetadata: Hashable, Sendable, Codable, Identifiable {
    public let id: AssetID
    public var kind: MediaKind
    public var traits: MediaTraits
    public var createdAt: Date?
    public var modifiedAt: Date?
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var coordinate: Coordinate?
    public var isFavorite: Bool
    public var isHidden: Bool
    public var duration: TimeInterval

    public init(
        id: AssetID,
        kind: MediaKind = .image,
        traits: MediaTraits = [],
        createdAt: Date? = nil,
        modifiedAt: Date? = nil,
        pixelWidth: Int = 0,
        pixelHeight: Int = 0,
        coordinate: Coordinate? = nil,
        isFavorite: Bool = false,
        isHidden: Bool = false,
        duration: TimeInterval = 0
    ) {
        self.id = id
        self.kind = kind
        self.traits = traits
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.coordinate = coordinate
        self.isFavorite = isFavorite
        self.isHidden = isHidden
        self.duration = duration
    }

    public var fingerprint: AssetFingerprint {
        AssetFingerprint(modifiedAt: modifiedAt)
    }
}
