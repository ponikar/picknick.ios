import Foundation
import PicknickCore

extension AssetMetadata {
    /// Builds a photo with sensible defaults so tests state only what matters.
    public static func fixture(
        id: AssetID,
        createdAt: Date = Date(timeIntervalSinceReferenceDate: 700_000_000),
        modifiedAt: Date? = nil,
        traits: MediaTraits = [],
        coordinate: Coordinate? = nil,
        isFavorite: Bool = false
    ) -> AssetMetadata {
        AssetMetadata(
            id: id,
            kind: .image,
            traits: traits,
            createdAt: createdAt,
            modifiedAt: modifiedAt ?? createdAt,
            pixelWidth: 4032,
            pixelHeight: 3024,
            coordinate: coordinate,
            isFavorite: isFavorite,
            isHidden: false,
            duration: 0
        )
    }

    /// A sequence of photos taken one minute apart, newest last.
    public static func sequence(count: Int, prefix: String = "asset") -> [AssetMetadata] {
        (0..<count).map { offset in
            .fixture(
                id: AssetID("\(prefix)-\(offset)"),
                createdAt: Date(timeIntervalSinceReferenceDate: 700_000_000 + Double(offset) * 60)
            )
        }
    }
}
