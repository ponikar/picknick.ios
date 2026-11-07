import Foundation

/// Converts embeddings to and from their stored form.
///
/// Vectors are persisted as `Float16`, which halves the resident cache at a
/// precision loss well below the noise floor of cosine ranking. Scoring
/// promotes back to `Float32`, which is what the vector units operate on.
enum VectorBlob {
    static func encode(_ values: [Float]) -> Data {
        var halves = values.map(Float16.init)
        return halves.withUnsafeMutableBufferPointer { buffer in
            Data(buffer: buffer)
        }
    }

    static func decode(_ data: Data, dimensions: Int) -> [Float] {
        let available = data.count / MemoryLayout<Float16>.size
        guard available >= dimensions else { return [] }

        return data.withUnsafeBytes { raw in
            let halves = raw.bindMemory(to: Float16.self)
            return (0..<dimensions).map { Float(halves[$0]) }
        }
    }
}
