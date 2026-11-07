import Foundation

/// Splits free text into lowercase search terms.
enum QueryTerms {
    private static let stopWords: Set<String> = [
        "a", "an", "and", "at", "by", "for", "from", "in", "into", "is", "it", "me",
        "my", "of", "on", "or", "photo", "photos", "picture", "pictures", "show",
        "the", "to", "with",
    ]

    static func words(in text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !stopWords.contains($0) }
    }

    /// Single words plus adjacent pairs, so a two-word label such as
    /// "golden retriever" matches its own phrase.
    static func labelTerms(in text: String) -> [String] {
        let words = words(in: text)
        guard words.count > 1 else { return words }
        let pairs = zip(words, words.dropFirst()).map { "\($0) \($1)" }
        return words + pairs
    }
}
