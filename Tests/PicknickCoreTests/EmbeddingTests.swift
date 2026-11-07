import PicknickCore
import Testing

@Suite("Embedding")
struct EmbeddingTests {
    @Test("Normalising yields unit length")
    func normalizes() {
        let embedding = Embedding(model: "test", values: [3, 4]).normalized()
        let magnitude = embedding.values.reduce(0) { $0 + $1 * $1 }

        #expect(abs(magnitude - 1) < 1e-6)
    }

    @Test("A zero vector survives normalisation unchanged")
    func zeroVector() {
        let embedding = Embedding(model: "test", values: [0, 0]).normalized()
        #expect(embedding.values == [0, 0])
    }
}
