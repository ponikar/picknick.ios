import Foundation
import PicknickCore

extension NormalizedRect {
    /// A face-sized box; `slot` spaces boxes apart so faces in one photo never overlap.
    public static func face(slot: Int = 0) -> NormalizedRect {
        NormalizedRect(x: 0.05 + Double(slot) * 0.15, y: 0.1, width: 0.1, height: 0.1)
    }
}

extension DetectedFace {
    /// A face whose fingerprint is `[value, 0]`, so the distance between two
    /// fixtures is exactly the difference of their values.
    public static func fixture(_ value: Float, box: NormalizedRect = .face()) -> DetectedFace {
        DetectedFace(boundingBox: box, fingerprint: [value, 0])
    }
}

extension FeatureRecord {
    public static func faces(_ asset: AssetID, _ faces: [DetectedFace]) -> FeatureRecord {
        FeatureRecord(assetID: asset, value: .faces(faces))
    }
}

extension IndexBatch {
    /// Photos with faces and a completed face stage, one entry per asset. Assets
    /// are created one minute apart in the order given, so the last is newest.
    public static func photos(
        _ entries: [(AssetID, [DetectedFace])],
        faceVersion: Int = 1,
        placeTerms: [AssetID: [String]] = [:]
    ) -> IndexBatch {
        IndexBatch(
            metadata: entries.enumerated().map { offset, entry in
                .fixture(id: entry.0, createdAt: Date(timeIntervalSinceReferenceDate: 700_000_000 + Double(offset) * 60))
            },
            features: entries.map { .faces($0.0, $0.1) },
            completions: entries.map { StageCompletion(assetID: $0.0, stage: .faces, version: faceVersion) },
            placeTerms: placeTerms
        )
    }
}
