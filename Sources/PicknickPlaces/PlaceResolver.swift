import PicknickCore

public struct PlaceResolver: Sendable {
    public let gazetteer: Gazetteer
    public let maxDistanceKm: Double

    public init(gazetteer: Gazetteer, maxDistanceKm: Double = Gazetteer.defaultMaxDistanceKm) {
        self.gazetteer = gazetteer
        self.maxDistanceKm = maxDistanceKm
    }

    public func place(for coordinate: Coordinate) -> Place? {
        gazetteer.nearest(to: coordinate, maxDistanceKm: maxDistanceKm)
    }

    public func searchTerms(for coordinate: Coordinate) -> [String] {
        place(for: coordinate)?.searchTerms ?? []
    }
}
