import Foundation

public enum MediaKind: Int, Sendable, Codable, CaseIterable {
    case unknown = 0
    case image = 1
    case video = 2
}

/// Subtypes that change how an asset is indexed or searched.
///
/// Stored as a bit field so the set survives a round trip through one integer
/// column and can be filtered in SQL with a mask.
public struct MediaTraits: OptionSet, Sendable, Codable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let screenshot = MediaTraits(rawValue: 1 << 0)
    public static let livePhoto = MediaTraits(rawValue: 1 << 1)
    public static let panorama = MediaTraits(rawValue: 1 << 2)
    public static let highDynamicRange = MediaTraits(rawValue: 1 << 3)
    public static let depthEffect = MediaTraits(rawValue: 1 << 4)
    public static let burst = MediaTraits(rawValue: 1 << 5)
    public static let timelapse = MediaTraits(rawValue: 1 << 6)
    public static let slowMotion = MediaTraits(rawValue: 1 << 7)
    public static let cinematic = MediaTraits(rawValue: 1 << 8)
    public static let screenRecording = MediaTraits(rawValue: 1 << 9)
    public static let spatial = MediaTraits(rawValue: 1 << 10)
}
