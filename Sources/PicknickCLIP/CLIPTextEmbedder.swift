import CoreML
import Foundation
import PicknickCore

/// Embeds search queries with the MobileCLIP text encoder, into the same space
/// as `CLIPImageExtractor`.
public struct CLIPTextEmbedder: TextEmbedder {
    public let model: String

    private let tokenizer: LazyValue<CLIPTokenizer>
    private let encoder: LazyValue<any CLIPTextModel>

    /// - Parameters:
    ///   - modelURL: a compiled `.mlmodelc` text encoder.
    ///   - mergesURL: the CLIP BPE merges file (`bpe_simple_vocab_16e6.txt` or `merges.txt`), uncompressed.
    public init(
        modelURL: URL,
        mergesURL: URL,
        modelID: String = "mobileclip-s2",
        computeUnits: MLComputeUnits = .all
    ) {
        self.init(
            modelID: modelID,
            loadTokenizer: { try CLIPTokenizer(mergesURL: mergesURL) },
            loadModel: { try CoreMLCLIPTextModel(contentsOf: modelURL, computeUnits: computeUnits) }
        )
    }

    public init(
        modelID: String,
        loadTokenizer: @escaping @Sendable () throws -> CLIPTokenizer,
        loadModel: @escaping @Sendable () throws -> any CLIPTextModel
    ) {
        self.model = modelID
        self.tokenizer = LazyValue(loadTokenizer)
        self.encoder = LazyValue(loadModel)
    }

    public func embed(_ text: String) async throws -> Embedding {
        let encoder = try encoder.get()
        let tokens = try tokenizer.get().encode(text, contextLength: encoder.contextLength)
        let values = try encoder.encode(tokens)
        guard !values.isEmpty else {
            throw CLIPError.predictionFailed("text encoder returned an empty vector")
        }
        return Embedding(model: model, values: values).normalized()
    }
}
