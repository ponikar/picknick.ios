import Foundation

/// Turns a search query into a vector in the same space as the image
/// embeddings, so the two can be compared with cosine similarity.
public protocol TextEmbedder: Sendable {
    var model: String { get }

    func embed(_ text: String) async throws -> Embedding
}
