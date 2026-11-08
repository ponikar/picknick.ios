import CoreGraphics
import Foundation
import ImageIO
import PicknickCore
import PicknickVision
import Testing

/// Real face photos cannot be generated offline. Point PICKNICK_FACE_FIXTURES at a
/// folder holding `1.jpg` (one clear face) and `3.jpg` (three clear faces).
private let fixtureFolder = ProcessInfo.processInfo.environment["PICKNICK_FACE_FIXTURES"]

private func loadFixture(_ name: String) throws -> CGImage {
    let url = URL(fileURLWithPath: try #require(fixtureFolder)).appendingPathComponent(name)
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: 1024,
        kCGImageSourceCreateThumbnailWithTransform: true,
    ]
    return try #require(CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary))
}

private func faces(in image: CGImage) async throws -> [DetectedFace] {
    let value = try await VisionFaceExtractor().extract(ExtractionContext(metadata: AssetMetadata(id: "photo"), image: image))
    guard case .faces(let faces) = value else {
        Issue.record("expected .faces, got \(String(describing: value))")
        return []
    }
    return faces
}

private func isNormalized(_ box: NormalizedRect) -> Bool {
    box.x >= 0 && box.y >= 0 && box.width > 0 && box.height > 0
        && box.x + box.width <= 1.0001 && box.y + box.height <= 1.0001
}

@Suite("VisionFaceExtractor")
struct VisionFaceExtractorTests {
    @Test("Runs as the face stage on a 1024 px image")
    func stage() {
        let extractor = VisionFaceExtractor()
        #expect(extractor.stage == .faces)
        #expect(extractor.preferredPixelSize == 1024)
    }

    @Test("R-02: an image with no faces yields .faces([]), never nil")
    func blankImage() async throws {
        let value = try await VisionFaceExtractor().extract(
            ExtractionContext(metadata: AssetMetadata(id: "blank"), image: ImageFixtures.scene(width: 1024, height: 768))
        )
        #expect(value == .faces([]))
    }

    @Test("R-01: one face gives one record with a box and fingerprint", .enabled(if: fixtureFolder != nil))
    func oneFace() async throws {
        let found = try await faces(in: try loadFixture("1.jpg"))
        #expect(found.count == 1)
        #expect(found.allSatisfy { isNormalized($0.boundingBox) && !$0.fingerprint.isEmpty })
    }

    @Test("R-01: three faces give three records with distinct boxes", .enabled(if: fixtureFolder != nil))
    func threeFaces() async throws {
        let found = try await faces(in: try loadFixture("3.jpg"))
        #expect(found.count == 3)
        #expect(Set(found.map(\.boundingBox)).count == 3)
        #expect(found.allSatisfy { isNormalized($0.boundingBox) && !$0.fingerprint.isEmpty })
    }

    @Test("Boxes use a top-left origin", .enabled(if: fixtureFolder != nil))
    func topLeftOrigin() async throws {
        let photo = try loadFixture("1.jpg")
        let side = 1024
        let context = ImageFixtures.context(width: side, height: side)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let scale = min(Double(side) / Double(photo.width), Double(side / 2) / Double(photo.height))
        let drawn = CGSize(width: Double(photo.width) * scale, height: Double(photo.height) * scale)
        // Core Graphics is bottom-left, so y = side - height puts the photo in the top half.
        context.draw(photo, in: CGRect(x: 0, y: Double(side) - drawn.height, width: drawn.width, height: drawn.height))

        let found = try await faces(in: try #require(context.makeImage()))

        let box = try #require(found.first?.boundingBox)
        #expect(box.y + box.height <= 0.5)
    }
}
