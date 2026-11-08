import Foundation
import PicknickCore

extension SQLiteIndexStore: SearchableIndex {
    private static let maximumTerms = 64

    public func embeddingRevision() -> Int {
        embeddingGeneration
    }

    public func embeddings(model: String, dimensions: Int) throws -> EmbeddingMatrix {
        let database = try requireConnection()
        var ids: [AssetID] = []
        var values: [Float] = []

        _ = try database.query(
            "SELECT asset_id, vector FROM embedding WHERE model = ? AND dimensions = ? ORDER BY asset_id",
            [.text(model), SQLiteValue(dimensions)]
        ) { row in
            let vector = VectorBlob.decode(row.data(1), dimensions: dimensions)
            guard vector.count == dimensions else { return }
            ids.append(AssetID(row.string(0)))
            values.append(contentsOf: vector)
        }

        return EmbeddingMatrix(model: model, dimensions: dimensions, ids: ids, values: values)
    }

    public func labelMatches(_ terms: [String], filter: SearchFilter, limit: Int) throws -> [LexicalMatch] {
        let terms = Self.normalized(terms)
        guard !terms.isEmpty, limit > 0 else { return [] }
        let database = try requireConnection()
        let (filterSQL, filterBindings) = Self.filterClause(filter)
        let placeholders = Array(repeating: "?", count: terms.count).joined(separator: ", ")

        return try database.query(
            """
            SELECT l.asset_id, SUM(l.confidence) AS score
            FROM label l JOIN asset a ON a.id = l.asset_id
            WHERE lower(replace(l.identifier, '_', ' ')) IN (\(placeholders)) AND \(filterSQL)
            GROUP BY l.asset_id
            ORDER BY score DESC, l.asset_id
            LIMIT ?
            """,
            terms.map { .text($0) } + filterBindings + [SQLiteValue(limit)]
        ) { LexicalMatch(id: AssetID($0.string(0)), score: $0.double(1)) }
    }

    public func textMatches(_ terms: [String], filter: SearchFilter, limit: Int) throws -> [LexicalMatch] {
        try fullTextMatches(terms, column: "content", requireAll: true, filter: filter, limit: limit)
    }

    public func placeMatches(_ terms: [String], filter: SearchFilter, limit: Int) throws -> [LexicalMatch] {
        try fullTextMatches(terms, column: "place", requireAll: false, filter: filter, limit: limit)
    }

    public func assets(matching filter: SearchFilter, limit: Int?) throws -> [AssetID] {
        let database = try requireConnection()
        let (filterSQL, filterBindings) = Self.filterClause(filter)

        return try database.query(
            """
            SELECT a.id FROM asset a
            WHERE \(filterSQL)
            ORDER BY a.created_at DESC, a.id
            LIMIT ?
            """,
            filterBindings + [SQLiteValue(limit ?? -1)]
        ) { AssetID($0.string(0)) }
    }
}

private extension SQLiteIndexStore {
    /// BM25 hits within one `asset_search` column. The table's tokenizer folds
    /// case and diacritics on both the stored text and the query.
    ///
    /// OCR text requires every term, so one shared word ("plate" on a parking
    /// ticket) does not match "plate of food". Places match any term, because the
    /// rest of a query like "dog in lisbon" describes the photo, not the place.
    func fullTextMatches(_ terms: [String], column: String, requireAll: Bool, filter: SearchFilter, limit: Int) throws -> [LexicalMatch] {
        let terms = Self.normalized(terms)
        guard !terms.isEmpty, limit > 0 else { return [] }
        let database = try requireConnection()
        let (filterSQL, filterBindings) = Self.filterClause(filter)

        // Each term is quoted so user input can never be parsed as FTS5 syntax.
        let expression = terms
            .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            .joined(separator: requireAll ? " AND " : " OR ")

        return try database.query(
            """
            SELECT s.asset_id, bm25(asset_search) AS rank
            FROM asset_search s JOIN asset a ON a.id = s.asset_id
            WHERE asset_search MATCH ? AND \(filterSQL)
            ORDER BY rank, s.asset_id
            LIMIT ?
            """,
            [.text("\(column) : (\(expression))")] + filterBindings + [SQLiteValue(limit)]
        ) { LexicalMatch(id: AssetID($0.string(0)), score: -$0.double(1)) }
    }

    static func normalized(_ terms: [String]) -> [String] {
        var seen: Set<String> = []
        return terms
            .map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .prefix(maximumTerms)
            .map { $0 }
    }

}

extension SQLiteIndexStore {
    /// A `WHERE` fragment over alias `a`, always valid even with no constraints.
    static func filterClause(_ filter: SearchFilter) -> (String, [SQLiteValue]) {
        var clauses = ["1 = 1"]
        var bindings: [SQLiteValue] = []

        if let interval = filter.createdIn {
            clauses.append("a.created_at BETWEEN ? AND ?")
            bindings.append(SQLiteValue(interval.start))
            bindings.append(SQLiteValue(interval.end))
        }
        if let kinds = filter.kinds {
            let raw = kinds.map(\.rawValue).sorted()
            if raw.isEmpty {
                clauses.append("0 = 1")
            } else {
                clauses.append("a.kind IN (\(Array(repeating: "?", count: raw.count).joined(separator: ", ")))")
                bindings.append(contentsOf: raw.map { SQLiteValue($0) })
            }
        }
        if !filter.requiredTraits.isEmpty {
            clauses.append("(a.traits & ?) = ?")
            bindings.append(SQLiteValue(filter.requiredTraits.rawValue))
            bindings.append(SQLiteValue(filter.requiredTraits.rawValue))
        }
        if let hasLocation = filter.hasLocation {
            clauses.append(hasLocation ? "a.latitude IS NOT NULL" : "a.latitude IS NULL")
        }
        if let isFavorite = filter.isFavorite {
            clauses.append("a.is_favorite = ?")
            bindings.append(SQLiteValue(isFavorite))
        }
        if !filter.includeHidden {
            clauses.append("a.is_hidden = 0")
        }

        return (clauses.joined(separator: " AND "), bindings)
    }
}
