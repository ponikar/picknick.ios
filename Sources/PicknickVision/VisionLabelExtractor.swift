import CoreGraphics
import PicknickCore
import Vision

/// Scene labels from Vision's built-in image classifier.
public struct VisionLabelExtractor: FeatureExtractor {
    public let stage: IndexStage = .labels
    public let version = 1
    public let preferredPixelSize: Int

    public let minimumConfidence: Float
    public let maximumCount: Int

    public init(minimumConfidence: Float = 0.1, maximumCount: Int = 20, preferredPixelSize: Int = 512) {
        precondition(maximumCount >= 0, "maximumCount must not be negative")
        self.minimumConfidence = minimumConfidence
        self.maximumCount = maximumCount
        self.preferredPixelSize = preferredPixelSize
    }

    public func extract(_ context: ExtractionContext) async throws -> FeatureValue? {
        let observations = try await ClassifyImageRequest().perform(on: context.image)
        let labels = Self.select(
            observations.map { Label(identifier: $0.identifier, confidence: $0.confidence) },
            minimumConfidence: minimumConfidence,
            maximumCount: maximumCount
        )
        return .labels(labels)
    }

    static func select(_ labels: [Label], minimumConfidence: Float, maximumCount: Int) -> [Label] {
        let kept = labels
            .filter { $0.confidence >= minimumConfidence }
            .sorted { $0.confidence != $1.confidence ? $0.confidence > $1.confidence : $0.identifier < $1.identifier }
        return Array(kept.prefix(maximumCount))
    }
}
