import CoreGraphics
import CoreVideo
import Foundation
import PicknickCore
import PicknickTestSupport
import Synchronization
import Testing
@testable import PicknickCLIP

final class FakeImageModel: CLIPImageModel {
    let inputSpec: CLIPImageInputSpec
    let output: [Float]
    let seenSizes = Mutex<[CGSize]>([])

    init(spec: CLIPImageInputSpec = CLIPImageInputSpec(width: 256, height: 256), output: [Float] = [3, 4]) {
        self.inputSpec = spec
        self.output = output
    }

    func encode(_ pixelBuffer: CVPixelBuffer) throws -> [Float] {
        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        seenSizes.withLock { $0.append(size) }
        return output
    }
}

final class FakeTextModel: CLIPTextModel {
    let contextLength = 77
    let seenTokens = Mutex<[[Int32]]>([])

    func encode(_ tokens: [Int32]) throws -> [Float] {
        seenTokens.withLock { $0.append(tokens) }
        return [0, 5]
    }
}

func solidImage(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

@Suite("CLIP image preprocessing")
struct CLIPImagePreprocessorTests {
    @Test("Output matches the model's input size and format")
    func size() throws {
        let spec = CLIPImageInputSpec(width: 256, height: 256)
        let buffer = try CLIPImagePreprocessor.pixelBuffer(
            from: solidImage(width: 640, height: 480, red: 1, green: 0, blue: 0), spec: spec
        )
        #expect(CVPixelBufferGetWidth(buffer) == 256)
        #expect(CVPixelBufferGetHeight(buffer) == 256)
        #expect(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA)
    }

    @Test("BGRA buffer carries red in the third byte, fully covered")
    func channelOrder() throws {
        let spec = CLIPImageInputSpec(width: 8, height: 8)
        let buffer = try CLIPImagePreprocessor.pixelBuffer(
            from: solidImage(width: 30, height: 10, red: 1, green: 0, blue: 0), spec: spec
        )
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)

        for (x, y) in [(0, 0), (7, 7), (4, 4)] {
            let pixel = base + y * rowBytes + x * 4
            #expect([pixel[0], pixel[1], pixel[2], pixel[3]] == [0, 0, 255, 255])
        }
    }

    @Test("Short side fills the target and the long side is center-cropped")
    func aspectFill() {
        let rect = CLIPImagePreprocessor.aspectFillRect(
            source: CGSize(width: 400, height: 200), target: CGSize(width: 256, height: 256)
        )
        #expect(rect == CGRect(x: -128, y: 0, width: 512, height: 256))
    }
}

@Suite("CLIP image extractor")
struct CLIPImageExtractorTests {
    let context = ExtractionContext(
        metadata: .fixture(id: AssetID("a")),
        image: solidImage(width: 512, height: 384, red: 0.2, green: 0.4, blue: 0.6)
    )

    @Test("Feeds the model a buffer of its input size and returns a normalized embedding")
    func extracts() async throws {
        let model = FakeImageModel()
        let extractor = CLIPImageExtractor(modelID: "mobileclip-s2") { model }

        let value = try await extractor.extract(context)

        #expect(extractor.stage == .embedding)
        #expect(value == .embedding(Embedding(model: "mobileclip-s2", values: [0.6, 0.8])))
        #expect(model.seenSizes.withLock { $0 } == [CGSize(width: 256, height: 256)])
    }

    @Test("The model loads once across concurrent extractions")
    func loadsOnce() async throws {
        let loads = Mutex(0)
        let model = FakeImageModel()
        let extractor = CLIPImageExtractor(modelID: "mobileclip-s2") {
            loads.withLock { $0 += 1 }
            return model
        }
        let context = self.context

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask { _ = try await extractor.extract(context) }
            }
            try await group.waitForAll()
        }
        #expect(loads.withLock { $0 } == 1)
    }

    @Test("A missing model file throws modelMissing, flagged as unavailable")
    func missingModel() async {
        let url = URL(fileURLWithPath: "/nonexistent/ImageEncoder.mlmodelc")
        let extractor = CLIPImageExtractor(modelURL: url)

        let error = await #expect(throws: CLIPError.modelMissing(url)) {
            try await extractor.extract(context)
        }
        #expect(error?.isModelUnavailable == true)
    }

    @Test("A corrupt model file throws modelInvalid")
    func corruptModel() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("picknick-corrupt-\(UUID().uuidString).mlmodelc")
        try Data("not a model".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let extractor = CLIPImageExtractor(modelURL: url)

        let error = await #expect(throws: CLIPError.self) { try await extractor.extract(context) }
        guard case .modelInvalid(url, _) = error else {
            Issue.record("expected modelInvalid, got \(String(describing: error))")
            return
        }
    }
}

@Suite("CLIP text embedder")
struct CLIPTextEmbedderTests {
    let mergesURL = Bundle.module.url(forResource: "tiny-merges", withExtension: "txt", subdirectory: "Fixtures")!

    @Test("Tokenizes to the model's context and returns a normalized embedding")
    func embeds() async throws {
        let model = FakeTextModel()
        let mergesURL = self.mergesURL
        let embedder = CLIPTextEmbedder(
            modelID: "mobileclip-s2",
            loadTokenizer: { try CLIPTokenizer(mergesURL: mergesURL) },
            loadModel: { model }
        )

        let embedding = try await embedder.embed("Cat")

        #expect(embedding == Embedding(model: "mobileclip-s2", values: [0, 1]))
        let tokens = try #require(model.seenTokens.withLock { $0 }.first)
        #expect(tokens.count == 77)
        #expect(Array(tokens.prefix(3)) == [516, 513, 517])
    }

    @Test("A missing text model throws modelMissing")
    func missingModel() async {
        let url = URL(fileURLWithPath: "/nonexistent/TextEncoder.mlmodelc")
        let embedder = CLIPTextEmbedder(modelURL: url, mergesURL: mergesURL)

        await #expect(throws: CLIPError.modelMissing(url)) {
            try await embedder.embed("cat")
        }
    }

    @Test("A missing merges file throws vocabularyMissing")
    func missingVocabulary() async {
        let url = URL(fileURLWithPath: "/nonexistent/merges.txt")
        let embedder = CLIPTextEmbedder(modelID: "mobileclip-s2", loadTokenizer: {
            try CLIPTokenizer(mergesURL: url)
        }, loadModel: { FakeTextModel() })

        await #expect(throws: CLIPError.vocabularyMissing(url)) {
            try await embedder.embed("cat")
        }
    }
}
