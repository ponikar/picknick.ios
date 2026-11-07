import Foundation
import PicknickCore
@testable import PicknickPlaces
import Testing

@Suite("Gazetteer")
struct GazetteerTests {
    static func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures"))
    }

    static func gazetteer() throws -> Gazetteer {
        try Gazetteer(
            citiesURL: fixture("cities"),
            countryInfoURL: fixture("countryInfo"),
            admin1CodesURL: fixture("admin1CodesASCII")
        )
    }

    @Test("Malformed lines are skipped, valid rows load")
    func skipsMalformedLines() throws {
        let gazetteer = try Self.gazetteer()
        #expect(gazetteer.entries.map(\.name) == ["Tokyo", "Lisbon", "Porto", "Suva", "Reykjavík"])
        #expect(gazetteer.skippedLineCount == 4)
        #expect(gazetteer.entries.first?.population == 8_336_599)
    }

    @Test("Nearest city resolves names through country and admin1 tables")
    func nearestCity() throws {
        let resolver = PlaceResolver(gazetteer: try Self.gazetteer())

        let shibuya = try #require(resolver.place(for: Coordinate(latitude: 35.6595, longitude: 139.7005)))
        #expect(shibuya.city == "Tokyo")
        #expect(shibuya.admin == "Tokyo")
        #expect(shibuya.country == "Japan")
        #expect(shibuya.countryCode == "JP")
        #expect(shibuya.distanceKm > 3 && shibuya.distanceKm < 4)

        let gaia = try #require(resolver.place(for: Coordinate(latitude: 41.1240, longitude: -8.6118)))
        #expect(gaia.city == "Porto")
        #expect(gaia.admin == "Porto")
        #expect(gaia.country == "Portugal")

        let reykjavik = try #require(resolver.place(for: Coordinate(latitude: 64.1466, longitude: -21.9426)))
        #expect(reykjavik.city == "Reykjavík")
        #expect(reykjavik.searchTerms == ["reykjavík", "capital region", "iceland"])
    }

    @Test("Lisbon and Porto are picked by distance, not grid order")
    func picksClosestOfSeveral() throws {
        let gazetteer = try Self.gazetteer()
        let between = Coordinate(latitude: 39.9, longitude: -8.9)
        #expect(gazetteer.nearest(to: between, maxDistanceKm: 500)?.city == "Lisbon")
    }

    @Test("Mid-ocean beyond the cutoff returns nil")
    func cutoffReturnsNil() throws {
        let resolver = PlaceResolver(gazetteer: try Self.gazetteer())
        #expect(resolver.place(for: Coordinate(latitude: 0, longitude: -140)) == nil)
        #expect(resolver.searchTerms(for: Coordinate(latitude: 0, longitude: -140)).isEmpty)
        #expect(resolver.place(for: Coordinate(latitude: 38.71667, longitude: -10.0)) == nil)
    }

    @Test("Lookup wraps across the antimeridian")
    func antimeridian() throws {
        let gazetteer = try Self.gazetteer()
        let eastOfLine = Coordinate(latitude: -18.14, longitude: -179.8)
        let suva = try #require(gazetteer.nearest(to: eastOfLine, maxDistanceKm: 300))
        #expect(suva.city == "Suva")
        #expect(suva.country == "Fiji")
        #expect(suva.distanceKm > 150 && suva.distanceKm < 200)

        let straddling = Gazetteer(entries: [
            GazetteerEntry(name: "West", coordinate: Coordinate(latitude: -16.5, longitude: -179.95), countryCode: "FJ"),
        ])
        let place = try #require(straddling.nearest(to: Coordinate(latitude: -16.5, longitude: 179.95)))
        #expect(place.city == "West")
        #expect(place.distanceKm < 12)
        #expect(place.admin == nil)
        #expect(place.country == "FJ")
    }

    @Test("Points near the poles search every longitude")
    func nearPole() throws {
        let gazetteer = Gazetteer(entries: [
            GazetteerEntry(name: "Pole Station", coordinate: Coordinate(latitude: 89.8, longitude: 120), countryCode: "AQ"),
        ])
        let place = try #require(gazetteer.nearest(to: Coordinate(latitude: 89.9, longitude: -60)))
        #expect(place.city == "Pole Station")
        #expect(place.distanceKm < 40)
    }

    @Test("Invalid coordinates resolve to nil")
    func invalidCoordinate() throws {
        let gazetteer = try Self.gazetteer()
        #expect(gazetteer.nearest(to: Coordinate(latitude: 120, longitude: 0)) == nil)
    }
}
