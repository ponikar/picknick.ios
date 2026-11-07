import Accelerate
import Foundation
import PicknickCore

/// An embedding matrix with every row scaled to unit length, so cosine
/// similarity reduces to one matrix-vector product.
struct NormalizedMatrix: Sendable {
    let model: String
    let dimensions: Int
    let ids: [AssetID]
    private let values: [Float]

    init(_ matrix: EmbeddingMatrix) {
        model = matrix.model
        dimensions = matrix.dimensions
        ids = matrix.ids

        var values = matrix.values
        let length = vDSP_Length(matrix.dimensions)
        values.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for row in 0..<matrix.count {
                let pointer = base + row * matrix.dimensions
                var sumOfSquares: Float = 0
                vDSP_svesq(pointer, 1, &sumOfSquares, length)
                guard sumOfSquares > 0 else { continue }
                var magnitude = sumOfSquares.squareRoot()
                vDSP_vsdiv(pointer, 1, &magnitude, pointer, 1, length)
            }
        }
        self.values = values
    }

    var count: Int { ids.count }

    /// Cosine similarity of `query` against every row, in row order.
    func similarities(to query: [Float]) -> [Float] {
        precondition(query.count == dimensions, "query dimensions do not match matrix")
        guard count > 0 else { return [] }

        let unitQuery = Embedding(model: model, values: query).normalized().values
        var scores = [Float](repeating: 0, count: count)
        vDSP_mmul(
            values, 1,
            unitQuery, 1,
            &scores, 1,
            vDSP_Length(count), 1, vDSP_Length(dimensions)
        )
        return scores
    }
}
