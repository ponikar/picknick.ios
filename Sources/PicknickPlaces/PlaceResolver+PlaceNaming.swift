import PicknickCore

extension PlaceResolver: PlaceNaming {
    public func placeTerms(for coordinate: Coordinate) -> [String] {
        searchTerms(for: coordinate)
    }
}
