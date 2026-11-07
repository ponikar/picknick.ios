import Foundation

public struct Place: Hashable, Sendable, Codable {
    public let city: String
    public let admin: String?
    public let country: String
    public let countryCode: String
    public let distanceKm: Double

    public init(city: String, admin: String?, country: String, countryCode: String, distanceKm: Double) {
        self.city = city
        self.admin = admin
        self.country = country
        self.countryCode = countryCode
        self.distanceKm = distanceKm
    }

    /// Lowercased, de-duplicated city, admin and country names for the search index.
    public var searchTerms: [String] {
        var seen = Set<String>()
        return [city, admin, country]
            .compactMap { $0?.lowercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
