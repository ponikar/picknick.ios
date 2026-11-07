import CoreGraphics
import PicknickCore
import Vision

/// Text lines from Vision's accurate recogniser.
///
/// Bounding boxes are normalised to the image (0...1) with a **top-left**
/// origin, matching UIKit/SwiftUI rather than Vision's bottom-left convention.
public struct VisionTextExtractor: FeatureExtractor {
    public enum Scope: Sendable, Hashable {
        /// Run only on assets carrying at least one of these traits.
        case traits(MediaTraits)
        case allAssets
    }

    public let stage: IndexStage = .text
    public let version = 1
    public let preferredPixelSize: Int

    public let scope: Scope
    public let usesLanguageCorrection: Bool

    public init(scope: Scope = .traits(.screenshot), usesLanguageCorrection: Bool = true, preferredPixelSize: Int = 2048) {
        self.scope = scope
        self.usesLanguageCorrection = usesLanguageCorrection
        self.preferredPixelSize = preferredPixelSize
    }

    public func shouldRun(for metadata: AssetMetadata) -> Bool {
        switch scope {
        case .allAssets: true
        case .traits(let traits): !metadata.traits.isDisjoint(with: traits)
        }
    }

    public func extract(_ context: ExtractionContext) async throws -> FeatureValue? {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = usesLanguageCorrection

        let observations = try await request.perform(on: context.image)
        let lines = observations.compactMap { observation -> PicknickCore.RecognizedText.Line? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let content = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return nil }
            return PicknickCore.RecognizedText.Line(
                content: content,
                confidence: candidate.confidence,
                boundingBox: Self.topLeftRect(fromBottomLeft: observation.boundingBox.cgRect)
            )
        }
        return .text(PicknickCore.RecognizedText(lines: lines))
    }

    static func topLeftRect(fromBottomLeft rect: CGRect) -> PicknickCore.NormalizedRect {
        PicknickCore.NormalizedRect(
            x: rect.minX,
            y: 1 - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }
}
