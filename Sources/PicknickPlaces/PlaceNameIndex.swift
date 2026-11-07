import Foundation
import PicknickCore

/// Country names plus large cities, as a `PlaceVocabulary` for search.
///
/// Only big places are included so ordinary words are rarely mistaken for one:
/// cities15000 has towns called "Ski", "Orange" and "Buffalo".
public struct PlaceNameIndex: PlaceVocabulary {
    public static let defaultMinimumPopulation = 1_000_000
    /// Country names that are also everyday words.
    public static let ambiguousCountries: Set<String> = ["chad", "china", "georgia", "guinea", "jordan", "niger", "turkey"]

    private let names: Set<String>

    public init(gazetteer: Gazetteer, minimumPopulation: Int = defaultMinimumPopulation) {
        var names = Set(gazetteer.countries.map(Self.fold)).subtracting(Self.ambiguousCountries)
        for entry in gazetteer.entries where entry.population >= minimumPopulation {
            names.insert(Self.fold(entry.name))
        }
        self.names = names
    }

    public init(names: [String]) {
        self.names = Set(names.map(Self.fold))
    }

    public func isPlaceName(_ phrase: String) -> Bool {
        names.contains(Self.fold(phrase))
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
    }
}
