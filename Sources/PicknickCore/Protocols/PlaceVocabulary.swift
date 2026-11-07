import Foundation

/// Recognizes well-known place names in a query, so search can answer them
/// from location data instead of from what a photo looks like.
public protocol PlaceVocabulary: Sendable {
    /// `phrase` is lowercased; implementations fold diacritics themselves.
    func isPlaceName(_ phrase: String) -> Bool
}
