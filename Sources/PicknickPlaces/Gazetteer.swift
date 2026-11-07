import Foundation
import PicknickCore

public struct GazetteerEntry: Hashable, Sendable {
    public let name: String
    public let coordinate: Coordinate
    public let countryCode: String
    public let admin1Code: String
    public let population: Int

    public init(name: String, coordinate: Coordinate, countryCode: String, admin1Code: String = "", population: Int = 0) {
        self.name = name
        self.coordinate = coordinate
        self.countryCode = countryCode
        self.admin1Code = admin1Code
        self.population = population
    }
}

/// Offline city lookup over GeoNames data (cities15000.txt layout), indexed by a 1° lat/lon grid.
public struct Gazetteer: Sendable {
    public static let defaultMaxDistanceKm = 50.0

    public let entries: [GazetteerEntry]
    public let skippedLineCount: Int
    private let countryNames: [String: String]
    private let admin1Names: [String: String]
    private let cells: [[Int32]]

    private static let latitudeCells = 181
    private static let longitudeCells = 360
    private static let earthRadiusKm = 6371.0088

    public init(
        entries: [GazetteerEntry],
        countryNames: [String: String] = [:],
        admin1Names: [String: String] = [:],
        skippedLineCount: Int = 0
    ) {
        self.entries = entries
        self.countryNames = countryNames
        self.admin1Names = admin1Names
        self.skippedLineCount = skippedLineCount

        var cells = [[Int32]](repeating: [], count: Self.latitudeCells * Self.longitudeCells)
        for (index, entry) in entries.enumerated() {
            let row = Self.latitudeRow(entry.coordinate.latitude)
            let column = Self.longitudeColumn(Int(entry.coordinate.longitude.rounded(.down)))
            cells[row * Self.longitudeCells + column].append(Int32(index))
        }
        self.cells = cells
    }

    /// Loads files the host app ships itself; this type never touches the network.
    public init(citiesURL: URL, countryInfoURL: URL? = nil, admin1CodesURL: URL? = nil) throws {
        let cities = Self.parseCities(try String(contentsOf: citiesURL, encoding: .utf8))
        let countries = try countryInfoURL.map { Self.parseCountryInfo(try String(contentsOf: $0, encoding: .utf8)) } ?? [:]
        let admin1 = try admin1CodesURL.map { Self.parseAdmin1Codes(try String(contentsOf: $0, encoding: .utf8)) } ?? [:]
        self.init(entries: cities.entries, countryNames: countries, admin1Names: admin1, skippedLineCount: cities.skipped)
    }

    public var countries: [String] { Array(countryNames.values) }

    public func nearest(to coordinate: Coordinate, maxDistanceKm: Double = defaultMaxDistanceKm) -> Place? {
        guard coordinate.isValid, maxDistanceKm >= 0, !entries.isEmpty else { return nil }

        var best: (index: Int, distance: Double)?
        for index in candidateIndices(around: coordinate, radiusKm: maxDistanceKm) {
            let distance = Self.haversineKm(coordinate, entries[index].coordinate)
            if distance <= maxDistanceKm, distance < (best?.distance ?? .infinity) {
                best = (index, distance)
            }
        }
        return best.map { place(for: entries[$0.index], distanceKm: $0.distance) }
    }

    private func place(for entry: GazetteerEntry, distanceKm: Double) -> Place {
        Place(
            city: entry.name,
            admin: entry.admin1Code.isEmpty ? nil : admin1Names["\(entry.countryCode).\(entry.admin1Code)"],
            country: countryNames[entry.countryCode] ?? entry.countryCode,
            countryCode: entry.countryCode,
            distanceKm: distanceKm
        )
    }

    private func candidateIndices(around coordinate: Coordinate, radiusKm: Double) -> [Int] {
        let radiusDegrees = radiusKm / Self.earthRadiusKm * 180 / .pi
        let latitude = coordinate.latitude
        let rows = Self.latitudeRow(max(-90, latitude - radiusDegrees))...Self.latitudeRow(min(90, latitude + radiusDegrees))

        let columns: [Int]
        let radians = radiusKm / Self.earthRadiusKm
        let reachesPole = latitude + radiusDegrees >= 90 || latitude - radiusDegrees <= -90
        let cosLatitude = cos(latitude * .pi / 180)
        if reachesPole || radians >= .pi / 2 || sin(radians) >= cosLatitude {
            columns = Array(0..<Self.longitudeCells)
        } else {
            // Exact longitude half-width of a spherical cap at this latitude (not the naive d / cos φ).
            let spanDegrees = asin(sin(radians) / cosLatitude) * 180 / .pi
            let low = Int((coordinate.longitude - spanDegrees).rounded(.down))
            let high = Int((coordinate.longitude + spanDegrees).rounded(.down))
            columns = high - low + 1 >= Self.longitudeCells
                ? Array(0..<Self.longitudeCells)
                : (low...high).map(Self.longitudeColumn)
        }

        var result: [Int] = []
        for row in rows {
            for column in columns {
                result.append(contentsOf: cells[row * Self.longitudeCells + column].lazy.map { Int($0) })
            }
        }
        return result
    }

    private static func latitudeRow(_ latitude: Double) -> Int {
        min(latitudeCells - 1, max(0, Int(latitude.rounded(.down)) + 90))
    }

    private static func longitudeColumn(_ degree: Int) -> Int {
        ((degree + 180) % longitudeCells + longitudeCells) % longitudeCells
    }

    static func haversineKm(_ a: Coordinate, _ b: Coordinate) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadiusKm * asin(min(1, h.squareRoot()))
    }
}

extension Gazetteer {
    /// Parses GeoNames city rows: geonameid, name, asciiname, alternatenames, latitude, longitude,
    /// feature class, feature code, country code, cc2, admin1 code, …, population (column 14), ….
    public static func parseCities(_ text: String) -> (entries: [GazetteerEntry], skipped: Int) {
        var entries: [GazetteerEntry] = []
        var skipped = 0
        for line in text.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count > 10,
                  let latitude = Double(fields[4]),
                  let longitude = Double(fields[5])
            else {
                skipped += 1
                continue
            }
            let coordinate = Coordinate(latitude: latitude, longitude: longitude)
            let name = fields[1].isEmpty ? String(fields[2]) : String(fields[1])
            let countryCode = String(fields[8])
            guard coordinate.isValid, !name.isEmpty, !countryCode.isEmpty else {
                skipped += 1
                continue
            }
            entries.append(GazetteerEntry(
                name: name,
                coordinate: coordinate,
                countryCode: countryCode,
                admin1Code: String(fields[10]),
                population: fields.count > 14 ? Int(fields[14]) ?? 0 : 0
            ))
        }
        return (entries, skipped)
    }

    /// Parses countryInfo.txt into ISO code → country name (column 4); `#` lines are comments.
    public static func parseCountryInfo(_ text: String) -> [String: String] {
        parseKeyedNames(text, keyColumn: 0, nameColumn: 4)
    }

    /// Parses admin1CodesASCII.txt into "CC.code" → admin area name (column 1).
    public static func parseAdmin1Codes(_ text: String) -> [String: String] {
        parseKeyedNames(text, keyColumn: 0, nameColumn: 1)
    }

    private static func parseKeyedNames(_ text: String, keyColumn: Int, nameColumn: Int) -> [String: String] {
        var names: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count > max(keyColumn, nameColumn), !fields[keyColumn].isEmpty, !fields[nameColumn].isEmpty else { continue }
            names[String(fields[keyColumn])] = String(fields[nameColumn])
        }
        return names
    }
}
