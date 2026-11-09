import Foundation

/// One face found in a photo. `boundingBox` is normalized 0-1 with a top-left origin.
public struct DetectedFace: Hashable, Sendable {
    public let boundingBox: NormalizedRect
    public let fingerprint: [Float]

    public init(boundingBox: NormalizedRect, fingerprint: [Float]) {
        self.boundingBox = boundingBox
        self.fingerprint = fingerprint
    }
}

/// Asset id plus the box rounded to 3 decimals, so re-detecting the same face
/// in the same image yields the same id and user names survive re-indexing.
public struct FaceID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(asset: AssetID, box: NormalizedRect) {
        let parts = [box.x, box.y, box.width, box.height].map { String(format: "%.3f", $0) }
        rawValue = asset.rawValue + "#" + parts.joined(separator: ",")
    }

    public var description: String { rawValue }
}

public struct FaceRef: Hashable, Sendable {
    public let id: FaceID
    public let assetID: AssetID
    public let boundingBox: NormalizedRect

    public init(id: FaceID, assetID: AssetID, boundingBox: NormalizedRect) {
        self.id = id
        self.assetID = assetID
        self.boundingBox = boundingBox
    }
}

public struct FaceGroup: Hashable, Sendable {
    public let id: Int
    /// The name every named face in the group shares, if they agree.
    public let name: String?
    public let photoCount: Int
    public let faces: [FaceRef]

    public init(id: Int, name: String?, photoCount: Int, faces: [FaceRef]) {
        self.id = id
        self.name = name
        self.photoCount = photoCount
        self.faces = faces
    }
}
