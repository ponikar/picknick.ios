import Foundation
import PicknickCore

extension SQLiteIndexStore: AssetContextReader {
    public func context(for ids: [AssetID]) throws -> [AssetContext] {
        let assets = try metadata(for: ids)
        guard !assets.isEmpty else { return [] }
        let database = try requireConnection()

        var labels: [AssetID: [Label]] = [:]
        var texts: [AssetID: RecognizedText] = [:]

        for chunk in assets.map(\.id).chunked(into: Self.bindingChunkSize) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            let bindings: [SQLiteValue] = chunk.map { .text($0.rawValue) }

            _ = try database.query(
                """
                SELECT asset_id, identifier, confidence FROM label
                WHERE asset_id IN (\(placeholders))
                ORDER BY confidence DESC, identifier
                """,
                bindings
            ) { row in
                let label = Label(identifier: row.string(1), confidence: Float(row.double(2)))
                labels[AssetID(row.string(0)), default: []].append(label)
            }

            _ = try database.query(
                "SELECT asset_id, geometry FROM recognized_text WHERE asset_id IN (\(placeholders))",
                bindings
            ) { row in
                guard let lines = try? JSONDecoder().decode([RecognizedText.Line].self, from: row.data(1)) else { return }
                texts[AssetID(row.string(0))] = RecognizedText(lines: lines)
            }
        }

        return assets.map { asset in
            AssetContext(metadata: asset, labels: labels[asset.id] ?? [], text: texts[asset.id])
        }
    }
}
