import CoreML
import Foundation
import PicknickCore

/// The `.embedding` stage backed by a MobileCLIP image encoder.
///
/// The host app owns the model file and passes its location in; nothing is
/// bundled or downloaded here. The model loads on first use and is shared
/// across concurrent extractions.
public struct CLIPImageExtractor: FeatureExtractor {
    public let stage: IndexStage = .embedding
    public let version: Int
    public let preferredPixelSize: Int
    public let modelID: String

    private let model: LazyValue<any CLIPImageModel>

    /// - Parameter modelURL: a compiled `.mlmodelc` image encoder.
    public init(
        modelURL: URL,
        modelID: String = "mobileclip-s2",
        version: Int = 1,
        preferredPixelSize: Int = 512,
        computeUnits: MLComputeUnits = .all
    ) {
        self.init(modelID: modelID, version: version, preferredPixelSize: preferredPixelSize) {
            try CoreMLCLIPImageModel(contentsOf: modelURL, computeUnits: computeUnits)
        }
    }

    public init(
        modelID: String,
        version: Int = 1,
        preferredPixelSize: Int = 512,
        loadModel: @escaping @Sendable () throws -> any CLIPImageModel
    ) {
        self.modelID = modelID
        self.version = version
        self.preferredPixelSize = preferredPixelSize
        self.model = LazyValue(loadModel)
    }

    public func extract(_ context: ExtractionContext) async throws -> FeatureValue? {
        let model = try model.get()
        let buffer = try CLIPImagePreprocessor.pixelBuffer(from: context.image, spec: model.inputSpec)
        let values = try model.encode(buffer)
        guard !values.isEmpty else {
            throw CLIPError.predictionFailed("image encoder returned an empty vector")
        }
        return .embedding(Embedding(model: modelID, values: values).normalized())
    }
}
