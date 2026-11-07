import CoreML
import CoreVideo
import Foundation

/// Size and pixel layout the image encoder expects.
public struct CLIPImageInputSpec: Hashable, Sendable {
    public let width: Int
    public let height: Int
    public let pixelFormat: OSType

    public init(width: Int, height: Int, pixelFormat: OSType = kCVPixelFormatType_32BGRA) {
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
    }
}

/// The seam around the Core ML image encoder, so tests can run without weights.
public protocol CLIPImageModel: Sendable {
    var inputSpec: CLIPImageInputSpec { get }
    func encode(_ pixelBuffer: CVPixelBuffer) throws -> [Float]
}

/// The seam around the Core ML text encoder.
public protocol CLIPTextModel: Sendable {
    var contextLength: Int { get }
    func encode(_ tokens: [Int32]) throws -> [Float]
}

/// A compiled (`.mlmodelc`) MobileCLIP image encoder.
public final class CoreMLCLIPImageModel: CLIPImageModel, @unchecked Sendable {
    public let inputSpec: CLIPImageInputSpec
    private let model: MLModel
    private let inputName: String
    private let outputName: String
    private let lock = NSLock()

    public init(contentsOf url: URL, computeUnits: MLComputeUnits = .all) throws {
        model = try loadModel(at: url, computeUnits: computeUnits)
        let description = model.modelDescription

        guard let (name, input) = description.inputDescriptionsByName
            .sorted(by: { $0.key < $1.key })
            .first(where: { $0.value.type == .image }),
            let constraint = input.imageConstraint
        else {
            throw CLIPError.unsupportedModelInterface("expected an image input")
        }
        guard [kCVPixelFormatType_32BGRA, kCVPixelFormatType_32ARGB].contains(constraint.pixelFormatType) else {
            throw CLIPError.unsupportedModelInterface(
                "image input pixel format \(constraint.pixelFormatType) is not 32BGRA or 32ARGB"
            )
        }
        inputName = name
        inputSpec = CLIPImageInputSpec(
            width: constraint.pixelsWide,
            height: constraint.pixelsHigh,
            pixelFormat: constraint.pixelFormatType
        )
        outputName = try embeddingOutputName(description)
    }

    public func encode(_ pixelBuffer: CVPixelBuffer) throws -> [Float] {
        let input = try MLDictionaryFeatureProvider(dictionary: [
            inputName: MLFeatureValue(pixelBuffer: pixelBuffer)
        ])
        return try lock.withLock {
            try predictEmbedding(model, input: input, outputName: outputName)
        }
    }
}

/// A compiled (`.mlmodelc`) MobileCLIP text encoder taking a `[1, context]` token array.
public final class CoreMLCLIPTextModel: CLIPTextModel, @unchecked Sendable {
    public let contextLength: Int
    private let model: MLModel
    private let inputName: String
    private let inputType: MLMultiArrayDataType
    private let outputName: String
    private let lock = NSLock()

    public init(contentsOf url: URL, computeUnits: MLComputeUnits = .all) throws {
        model = try loadModel(at: url, computeUnits: computeUnits)
        let description = model.modelDescription

        guard let (name, input) = description.inputDescriptionsByName
            .sorted(by: { $0.key < $1.key })
            .first(where: { $0.value.type == .multiArray }),
            let constraint = input.multiArrayConstraint,
            let length = constraint.shape.last?.intValue, length > 2
        else {
            throw CLIPError.unsupportedModelInterface("expected a token array input")
        }
        inputName = name
        inputType = constraint.dataType
        contextLength = length
        outputName = try embeddingOutputName(description)
    }

    public func encode(_ tokens: [Int32]) throws -> [Float] {
        let array = try MLMultiArray(shape: [1, NSNumber(value: tokens.count)], dataType: inputType)
        for (index, token) in tokens.enumerated() {
            array[[0, NSNumber(value: index)]] = NSNumber(value: token)
        }
        let input = try MLDictionaryFeatureProvider(dictionary: [
            inputName: MLFeatureValue(multiArray: array)
        ])
        return try lock.withLock {
            try predictEmbedding(model, input: input, outputName: outputName)
        }
    }
}

private func loadModel(at url: URL, computeUnits: MLComputeUnits) throws -> MLModel {
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw CLIPError.modelMissing(url)
    }
    let configuration = MLModelConfiguration()
    configuration.computeUnits = computeUnits
    do {
        return try MLModel(contentsOf: url, configuration: configuration)
    } catch {
        throw CLIPError.modelInvalid(url, message: String(describing: error))
    }
}

private func embeddingOutputName(_ description: MLModelDescription) throws -> String {
    let arrays = description.outputDescriptionsByName
        .filter { $0.value.type == .multiArray }
        .map(\.key)
        .sorted()
    guard arrays.count == 1, let name = arrays.first else {
        throw CLIPError.unsupportedModelInterface(
            "expected exactly one array output, found \(arrays)"
        )
    }
    return name
}

/// Callers hold a per-model lock: Core ML does not document `MLModel`
/// prediction as safe to call concurrently on one instance.
private func predictEmbedding(
    _ model: MLModel,
    input: MLFeatureProvider,
    outputName: String
) throws -> [Float] {
    let output: MLFeatureProvider
    do {
        output = try model.prediction(from: input)
    } catch {
        throw CLIPError.predictionFailed(String(describing: error))
    }
    guard let array = output.featureValue(for: outputName)?.multiArrayValue else {
        throw CLIPError.predictionFailed("output \(outputName) missing")
    }
    return MLShapedArray<Float>(converting: array).scalars
}
