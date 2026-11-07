import Foundation
import PicknickCore

/// A configurable extractor that records what it saw.
public final class StubExtractor: FeatureExtractor, @unchecked Sendable {
    public let stage: IndexStage
    public let version: Int
    public let preferredPixelSize: Int

    private let gate: @Sendable (AssetMetadata) -> Bool
    private let produce: @Sendable (ExtractionContext) throws -> FeatureValue?
    private let lock = NSLock()
    private var seen: [AssetID] = []

    public init(
        stage: IndexStage,
        version: Int = 1,
        preferredPixelSize: Int = 512,
        gate: @escaping @Sendable (AssetMetadata) -> Bool = { _ in true },
        produce: @escaping @Sendable (ExtractionContext) throws -> FeatureValue? = { _ in nil }
    ) {
        self.stage = stage
        self.version = version
        self.preferredPixelSize = preferredPixelSize
        self.gate = gate
        self.produce = produce
    }

    public var processedAssets: [AssetID] {
        lock.withLock { seen }
    }

    public func shouldRun(for metadata: AssetMetadata) -> Bool {
        gate(metadata)
    }

    public func extract(_ context: ExtractionContext) async throws -> FeatureValue? {
        lock.withLock { seen.append(context.metadata.id) }
        return try produce(context)
    }
}

extension StubExtractor {
    /// Always yields a deterministic unit vector, so ranking assertions do not
    /// depend on a real model being present.
    public static func embedding(
        version: Int = 1,
        dimensions: Int = 8
    ) -> StubExtractor {
        StubExtractor(stage: .embedding, version: version, produce: { context in
            let seed = Float(abs(context.metadata.id.rawValue.hashValue % 97) + 1)
            let values = (0..<dimensions).map { Float($0 + 1) / seed }
            return .embedding(Embedding(model: "stub", values: values).normalized())
        })
    }

    public static func labels(_ identifiers: [String], version: Int = 1) -> StubExtractor {
        StubExtractor(stage: .labels, version: version, produce: { _ in
            .labels(identifiers.map { Label(identifier: $0, confidence: 0.9) })
        })
    }

    /// Mirrors the real gating rule: text recognition runs on screenshots only.
    public static func screenshotText(_ content: String, version: Int = 1) -> StubExtractor {
        StubExtractor(
            stage: .text,
            version: version,
            preferredPixelSize: 1024,
            gate: { $0.traits.contains(.screenshot) },
            produce: { _ in
                .text(
                    RecognizedText(lines: [
                        RecognizedText.Line(content: content, confidence: 0.95, boundingBox: .unit)
                    ])
                )
            }
        )
    }
}
