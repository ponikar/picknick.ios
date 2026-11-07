import Foundation

/// Structured constraints applied before any ranking.
///
/// A `nil` field means "no constraint". Hidden assets are excluded unless
/// asked for, matching what the Photos app shows in its own search.
public struct SearchFilter: Hashable, Sendable {
    public var createdIn: DateInterval?
    public var kinds: Set<MediaKind>?
    public var requiredTraits: MediaTraits
    public var hasLocation: Bool?
    public var isFavorite: Bool?
    public var includeHidden: Bool

    public init(
        createdIn: DateInterval? = nil,
        kinds: Set<MediaKind>? = nil,
        requiredTraits: MediaTraits = [],
        hasLocation: Bool? = nil,
        isFavorite: Bool? = nil,
        includeHidden: Bool = false
    ) {
        self.createdIn = createdIn
        self.kinds = kinds
        self.requiredTraits = requiredTraits
        self.hasLocation = hasLocation
        self.isFavorite = isFavorite
        self.includeHidden = includeHidden
    }

    public static let none = SearchFilter()
}
