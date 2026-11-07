import Foundation

/// Turns a coordinate into searchable place names (city, region, country).
///
/// Implementations must answer from on-device data only.
public protocol PlaceNaming: Sendable {
    func placeTerms(for coordinate: Coordinate) -> [String]
}
