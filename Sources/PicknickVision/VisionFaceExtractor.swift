import CoreGraphics
import Foundation
import PicknickCore
import Vision

/// Faces from Vision's face detector, each with a feature print of its crop.
///
/// Bounding boxes are normalised to the image (0...1) with a **top-left**
/// origin. Faces smaller than `minimumFacePixels` on their short side are
/// dropped, because their feature prints are too noisy to name.
public struct VisionFaceExtractor: FeatureExtractor {
    public let stage: IndexStage = .faces
    public let version = 1
    public let preferredPixelSize: Int

    public let minimumFacePixels: Int

    public init(minimumFacePixels: Int = 64, preferredPixelSize: Int = 1024) {
        self.minimumFacePixels = minimumFacePixels
        self.preferredPixelSize = preferredPixelSize
    }

    public func extract(_ context: ExtractionContext) async throws -> FeatureValue? {
        let image = context.image
        let size = CGSize(width: image.width, height: image.height)
        let observations = try await DetectFaceRectanglesRequest().perform(on: image)

        var seen: Set<FaceID> = []
        var faces: [DetectedFace] = []
        for observation in observations {
            let pixels = observation.boundingBox.toImageCoordinates(size, origin: .upperLeft).integral
            guard min(pixels.width, pixels.height) >= CGFloat(minimumFacePixels) else { continue }

            let box = VisionTextExtractor.topLeftRect(fromBottomLeft: observation.boundingBox.cgRect)
            guard seen.insert(FaceID(asset: context.metadata.id, box: box)).inserted else { continue }

            guard let crop = image.cropping(to: pixels) else { continue }
            let print = try await GenerateImageFeaturePrintRequest().perform(on: crop)
            faces.append(DetectedFace(boundingBox: box, fingerprint: Self.values(of: print)))
        }
        return .faces(faces)
    }

    static func values(of print: FeaturePrintObservation) -> [Float] {
        print.data.withUnsafeBytes { raw in
            switch print.elementType {
            case .float: Array(raw.bindMemory(to: Float.self).prefix(print.elementCount))
            case .double: raw.bindMemory(to: Double.self).prefix(print.elementCount).map(Float.init)
            @unknown default: []
            }
        }
    }
}
