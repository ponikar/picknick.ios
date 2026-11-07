import CoreGraphics
import Foundation

/// The image and metadata handed to a stage.
public struct ExtractionContext: Sendable {
    public let metadata: AssetMetadata
    public let image: CGImage

    public init(metadata: AssetMetadata, image: CGImage) {
        self.metadata = metadata
        self.image = image
    }
}

/// One derived signal, produced from one image.
///
/// An extractor is pure with respect to the index: it reads a context and
/// returns a value. Deciding when to run, how often, and what to do with the
/// result belongs to the coordinator.
public protocol FeatureExtractor: Sendable {
    var stage: IndexStage { get }

    /// Bump to invalidate every stored result for this stage.
    var version: Int { get }

    /// Longest edge, in pixels, of the image this stage wants. The coordinator
    /// loads one image per asset at the largest size any eligible stage asks
    /// for, so a stage that needs detail does not force every stage to pay.
    var preferredPixelSize: Int { get }

    /// Cheap gate evaluated before any image is loaded.
    ///
    /// Returning `false` marks the stage satisfied for that asset without
    /// running it, which is how text recognition stays confined to screenshots.
    func shouldRun(for metadata: AssetMetadata) -> Bool

    func extract(_ context: ExtractionContext) async throws -> FeatureValue?
}

extension FeatureExtractor {
    public var requirement: StageRequirement {
        StageRequirement(stage: stage, version: version)
    }

    public func shouldRun(for metadata: AssetMetadata) -> Bool { true }
}
