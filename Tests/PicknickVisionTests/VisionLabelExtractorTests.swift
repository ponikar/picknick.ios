import PicknickCore
@testable import PicknickVision
import Testing

@Suite("VisionLabelExtractor")
struct VisionLabelExtractorTests {
    @Test("Real classification is sorted, thresholded and capped")
    func classifiesGeneratedImage() async throws {
        let extractor = VisionLabelExtractor(minimumConfidence: 0.01, maximumCount: 5)
        let context = ExtractionContext(metadata: AssetMetadata(id: "scene"), image: ImageFixtures.scene())

        guard case .labels(let labels) = try await extractor.extract(context) else {
            Issue.record("expected .labels")
            return
        }

        #expect(!labels.isEmpty)
        #expect(labels.count <= 5)
        #expect(labels.allSatisfy { $0.confidence >= 0.01 })
        #expect(labels.map(\.confidence) == labels.map(\.confidence).sorted(by: >))
    }

    @Test("Selection drops low confidence, sorts descending and caps")
    func selection() {
        let input = [
            Label(identifier: "c", confidence: 0.2),
            Label(identifier: "a", confidence: 0.9),
            Label(identifier: "low", confidence: 0.05),
            Label(identifier: "b", confidence: 0.5),
        ]

        let selected = VisionLabelExtractor.select(input, minimumConfidence: 0.1, maximumCount: 2)

        #expect(selected.map(\.identifier) == ["a", "b"])
    }

    @Test("Defaults match the documented contract")
    func defaults() {
        let extractor = VisionLabelExtractor()
        #expect(extractor.stage == .labels)
        #expect(extractor.version == 1)
        #expect(extractor.minimumConfidence == 0.1)
        #expect(extractor.maximumCount == 20)
        #expect(extractor.shouldRun(for: AssetMetadata(id: "any")))
    }
}
