import Foundation

/// A semantic vector in a shared image/text space.
///
/// Stored as `Float16` to halve the resident cache; scoring promotes to
/// `Float32`, which is what the vector units want anyway.
public struct Embedding: Hashable, Sendable {
    public let model: String
    public let values: [Float]

    public init(model: String, values: [Float]) {
        self.model = model
        self.values = values
    }

    public var dimensions: Int { values.count }

    public func normalized() -> Embedding {
        var sum: Float = 0
        for value in values { sum += value * value }
        let magnitude = sum.squareRoot()
        guard magnitude > 0 else { return self }
        return Embedding(model: model, values: values.map { $0 / magnitude })
    }
}

public struct Label: Hashable, Sendable, Codable {
    public let identifier: String
    public let confidence: Float

    public init(identifier: String, confidence: Float) {
        self.identifier = identifier
        self.confidence = confidence
    }
}

/// Text recognised inside an image, kept as lines so a future viewer can map a
/// search hit back to a region without re-running recognition.
public struct RecognizedText: Hashable, Sendable, Codable {
    public struct Line: Hashable, Sendable, Codable {
        public let content: String
        public let confidence: Float
        public let boundingBox: NormalizedRect

        public init(content: String, confidence: Float, boundingBox: NormalizedRect) {
            self.content = content
            self.confidence = confidence
            self.boundingBox = boundingBox
        }
    }

    public let lines: [Line]

    public init(lines: [Line]) {
        self.lines = lines
    }

    public var joined: String {
        lines.map(\.content).joined(separator: "\n")
    }

    public var isEmpty: Bool { lines.isEmpty }
}

public struct NormalizedRect: Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let unit = NormalizedRect(x: 0, y: 0, width: 1, height: 1)
}

/// The closed set of results a stage can produce.
///
/// An enum rather than an associated type keeps heterogeneous extractor output
/// in one collection, which is what batching needs.
public enum FeatureValue: Hashable, Sendable {
    case embedding(Embedding)
    case labels([Label])
    case text(RecognizedText)

    public var stage: IndexStage {
        switch self {
        case .embedding: .embedding
        case .labels: .labels
        case .text: .text
        }
    }
}

public struct FeatureRecord: Hashable, Sendable {
    public let assetID: AssetID
    public let value: FeatureValue

    public init(assetID: AssetID, value: FeatureValue) {
        self.assetID = assetID
        self.value = value
    }

    public var stage: IndexStage { value.stage }
}
