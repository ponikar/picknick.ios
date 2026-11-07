import CoreGraphics
import PicknickCore
@testable import PicknickVision
import Testing

@Suite("VisionTextExtractor")
struct VisionTextExtractorTests {
    @Test("Recognises rendered text with a top-left bounding box")
    func recognisesText() async throws {
        let extractor = VisionTextExtractor()
        let context = ExtractionContext(
            metadata: AssetMetadata(id: "shot", traits: .screenshot),
            image: ImageFixtures.text("PICKNICK 2026")
        )

        guard case .text(let text) = try await extractor.extract(context) else {
            Issue.record("expected .text")
            return
        }

        let line = try #require(text.lines.first { $0.content.uppercased().contains("PICKNICK") })
        #expect(line.confidence > 0)
        #expect(line.boundingBox.x >= 0 && line.boundingBox.x + line.boundingBox.width <= 1)
        #expect(line.boundingBox.y >= 0 && line.boundingBox.y + line.boundingBox.height <= 1)
        #expect(line.boundingBox.y < 0.5)
    }

    @Test("Gates to screenshots by default")
    func defaultGate() {
        let extractor = VisionTextExtractor()
        #expect(extractor.stage == .text)
        #expect(extractor.version == 1)
        #expect(extractor.shouldRun(for: AssetMetadata(id: "s", traits: [.screenshot, .highDynamicRange])))
        #expect(!extractor.shouldRun(for: AssetMetadata(id: "p")))
        #expect(!extractor.shouldRun(for: AssetMetadata(id: "l", traits: .livePhoto)))
    }

    @Test("Can be configured to run on every asset")
    func allAssets() {
        let extractor = VisionTextExtractor(scope: .allAssets)
        #expect(extractor.shouldRun(for: AssetMetadata(id: "p")))
    }

    @Test("Bottom-left Vision rects flip to a top-left origin")
    func flipsOrigin() {
        let rect = VisionTextExtractor.topLeftRect(fromBottomLeft: CGRect(x: 0.1, y: 0.7, width: 0.5, height: 0.2))
        #expect(abs(rect.x - 0.1) < 1e-9)
        #expect(abs(rect.y - 0.1) < 1e-9)
        #expect(abs(rect.width - 0.5) < 1e-9)
        #expect(abs(rect.height - 0.2) < 1e-9)
    }
}
