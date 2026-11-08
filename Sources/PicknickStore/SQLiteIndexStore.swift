import Foundation
import PicknickCore

/// SQLite-backed `IndexStore`.
///
/// An actor rather than a lock: the write path is a single serialized stream of
/// batches, and confining the connection removes any question of cross-thread
/// use of the underlying handle.
public actor SQLiteIndexStore: IndexStore {
    private let path: String
    private var connection: SQLiteConnection?
    var embeddingGeneration = 0

    /// Faces whose fingerprints are at most this Euclidean distance apart are
    /// treated as the same person, for grouping and automatic naming.
    public let faceCutoff: Double

    /// From FaceCutoffEval on 200 LFW photos of 20 people: the only cutoff with
    /// at least 90% correct automatic names, though it names under 1% of faces.
    public static let defaultFaceCutoff = 0.68

    /// Parameter count per `IN` clause, kept well under SQLite's own limit so
    /// callers never have to think about how many ids they pass.
    static let bindingChunkSize = 400

    public init(path: String, faceCutoff: Double = SQLiteIndexStore.defaultFaceCutoff) {
        self.path = path
        self.faceCutoff = faceCutoff
    }

    /// An in-memory database, for tests and previews.
    public static func inMemory() -> SQLiteIndexStore {
        SQLiteIndexStore(path: ":memory:")
    }

    public func prepare() throws {
        guard connection == nil else { return }
        let connection = try SQLiteConnection(path: path)
        try Migrator.migrate(connection)
        self.connection = connection
    }

    public func fingerprints() throws -> [AssetID: AssetFingerprint] {
        let rows = try requireConnection().query("SELECT id, modified_at FROM asset") { row in
            (AssetID(row.string(0)), AssetFingerprint(modifiedAt: row.date(1)))
        }
        return Dictionary(uniqueKeysWithValues: rows)
    }

    public func commit(_ batch: IndexBatch) throws {
        guard !batch.isEmpty else { return }
        let database = try requireConnection()

        try database.transaction {
            var faceWork = FaceCommit()
            if try hasUserNames(among: batch.removals, in: database) {
                faceWork.namesChanged = true
            }

            for id in batch.removals {
                try database.run("DELETE FROM asset_search WHERE asset_id = ?", [.text(id.rawValue)])
                try database.run("DELETE FROM asset WHERE id = ?", [.text(id.rawValue)])
            }

            for metadata in batch.metadata {
                try upsert(metadata, in: database)
                try replacePlaceTerms(batch.placeTerms[metadata.id] ?? [], for: metadata.id, in: database)
            }

            for feature in batch.features {
                try apply(feature, faceWork: &faceWork, in: database)
            }

            try finishFaces(faceWork, in: database)

            for completion in batch.completions {
                try database.run(
                    """
                    INSERT INTO asset_stage (asset_id, stage, version, completed_at)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(asset_id, stage) DO UPDATE SET
                        version = excluded.version,
                        completed_at = excluded.completed_at
                    """,
                    [
                        .text(completion.assetID.rawValue),
                        .text(completion.stage.rawValue),
                        SQLiteValue(completion.version),
                        SQLiteValue(completion.completedAt),
                    ]
                )
                try database.run(
                    "DELETE FROM stage_failure WHERE asset_id = ? AND stage = ?",
                    [.text(completion.assetID.rawValue), .text(completion.stage.rawValue)]
                )
            }

            for failure in batch.failures {
                try database.run(
                    """
                    INSERT INTO stage_failure (asset_id, stage, reason, is_permanent, occurred_at)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(asset_id, stage) DO UPDATE SET
                        reason = excluded.reason,
                        is_permanent = excluded.is_permanent,
                        occurred_at = excluded.occurred_at
                    """,
                    [
                        .text(failure.assetID.rawValue),
                        .text(failure.stage.rawValue),
                        .text(failure.reason),
                        SQLiteValue(failure.isPermanent),
                        SQLiteValue(failure.occurredAt),
                    ]
                )
            }

            for id in searchRowsNeedingRefresh(in: batch) {
                try refreshSearchRow(for: id, in: database)
            }
        }

        if !batch.removals.isEmpty || batch.features.contains(where: { $0.stage == .embedding }) {
            embeddingGeneration += 1
        }
    }

    public func pendingWork(
        _ requirements: [StageRequirement],
        retryFailuresBefore: Date,
        limit: Int
    ) throws -> [PendingWork] {
        guard !requirements.isEmpty, limit > 0 else { return [] }
        let database = try requireConnection()

        var clauses: [String] = []
        var bindings: [SQLiteValue] = []

        for requirement in requirements {
            clauses.append(
                """
                (NOT EXISTS (
                    SELECT 1 FROM asset_stage s
                    WHERE s.asset_id = a.id AND s.stage = ? AND s.version >= ?
                 )
                 AND NOT EXISTS (
                    SELECT 1 FROM stage_failure f
                    WHERE f.asset_id = a.id AND f.stage = ?
                      AND (f.is_permanent = 1 OR f.occurred_at >= ?)
                 ))
                """
            )
            bindings.append(.text(requirement.stage.rawValue))
            bindings.append(SQLiteValue(requirement.version))
            bindings.append(.text(requirement.stage.rawValue))
            bindings.append(SQLiteValue(retryFailuresBefore))
        }

        bindings.append(SQLiteValue(limit))

        let candidates = try database.query(
            """
            SELECT \(Self.assetColumns) FROM asset a
            WHERE \(clauses.joined(separator: " OR "))
            ORDER BY a.created_at DESC
            LIMIT ?
            """,
            bindings,
            decode: Self.decodeAsset
        )

        guard !candidates.isEmpty else { return [] }

        let ids = candidates.map(\.id)
        let satisfied = try satisfiedStages(for: ids, requirements: requirements, in: database)
        let blocked = try suppressedStages(for: ids, retryFailuresBefore: retryFailuresBefore, in: database)

        let wanted = Set(requirements.map(\.stage))
        return candidates.compactMap { metadata in
            let outstanding = wanted
                .subtracting(satisfied[metadata.id] ?? [])
                .subtracting(blocked[metadata.id] ?? [])
            guard !outstanding.isEmpty else { return nil }
            return PendingWork(metadata: metadata, stages: outstanding)
        }
    }

    public func metadata(for ids: [AssetID]) throws -> [AssetMetadata] {
        guard !ids.isEmpty else { return [] }
        let database = try requireConnection()

        var results: [AssetMetadata] = []
        results.reserveCapacity(ids.count)

        for chunk in ids.chunked(into: Self.bindingChunkSize) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            let rows = try database.query(
                "SELECT \(Self.assetColumns) FROM asset a WHERE a.id IN (\(placeholders))",
                chunk.map { .text($0.rawValue) },
                decode: Self.decodeAsset
            )
            results.append(contentsOf: rows)
        }

        return results
    }

    public func statistics(for requirements: [StageRequirement]) throws -> IndexStatistics {
        let database = try requireConnection()

        let total = try database.query("SELECT COUNT(*) FROM asset") { $0.int(0) }.first ?? 0
        let failures = try database.query(
            "SELECT COUNT(*) FROM stage_failure WHERE is_permanent = 1"
        ) { $0.int(0) }.first ?? 0

        var completed: [IndexStage: Int] = [:]
        for requirement in requirements {
            let count = try database.query(
                "SELECT COUNT(*) FROM asset_stage WHERE stage = ? AND version >= ?",
                [.text(requirement.stage.rawValue), SQLiteValue(requirement.version)]
            ) { $0.int(0) }.first ?? 0
            completed[requirement.stage] = count
        }

        return IndexStatistics(
            totalAssets: total,
            completedByStage: completed,
            permanentFailures: failures
        )
    }
}

// MARK: - Stage bookkeeping

private extension SQLiteIndexStore {
    /// Stages already completed at or above the required version.
    func satisfiedStages(
        for ids: [AssetID],
        requirements: [StageRequirement],
        in database: SQLiteConnection
    ) throws -> [AssetID: Set<IndexStage>] {
        let minimumVersion = Dictionary(
            requirements.map { ($0.stage, $0.version) },
            uniquingKeysWith: max
        )

        var result: [AssetID: Set<IndexStage>] = [:]
        for chunk in ids.chunked(into: Self.bindingChunkSize) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            let rows = try database.query(
                "SELECT asset_id, stage, version FROM asset_stage WHERE asset_id IN (\(placeholders))",
                chunk.map { .text($0.rawValue) }
            ) { (AssetID($0.string(0)), $0.string(1), $0.int(2)) }

            for (id, rawStage, version) in rows {
                guard let stage = IndexStage(rawValue: rawStage),
                      let required = minimumVersion[stage],
                      version >= required
                else { continue }
                result[id, default: []].insert(stage)
            }
        }
        return result
    }

    /// Stages that must not be offered right now: permanently failed, or
    /// failed too recently to be worth another attempt.
    func suppressedStages(
        for ids: [AssetID],
        retryFailuresBefore: Date,
        in database: SQLiteConnection
    ) throws -> [AssetID: Set<IndexStage>] {
        var result: [AssetID: Set<IndexStage>] = [:]
        for chunk in ids.chunked(into: Self.bindingChunkSize) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            let rows = try database.query(
                """
                SELECT asset_id, stage FROM stage_failure
                WHERE (is_permanent = 1 OR occurred_at >= ?)
                  AND asset_id IN (\(placeholders))
                """,
                [SQLiteValue(retryFailuresBefore)] + chunk.map { .text($0.rawValue) }
            ) { (AssetID($0.string(0)), $0.string(1)) }

            for (id, rawStage) in rows {
                guard let stage = IndexStage(rawValue: rawStage) else { continue }
                result[id, default: []].insert(stage)
            }
        }
        return result
    }
}

// MARK: - Writing

private extension SQLiteIndexStore {
    func upsert(_ metadata: AssetMetadata, in database: SQLiteConnection) throws {
        try database.run(
            """
            INSERT INTO asset (
                id, kind, traits, created_at, modified_at, pixel_width, pixel_height,
                latitude, longitude, is_favorite, is_hidden, duration
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                kind = excluded.kind,
                traits = excluded.traits,
                created_at = excluded.created_at,
                modified_at = excluded.modified_at,
                pixel_width = excluded.pixel_width,
                pixel_height = excluded.pixel_height,
                latitude = excluded.latitude,
                longitude = excluded.longitude,
                is_favorite = excluded.is_favorite,
                is_hidden = excluded.is_hidden,
                duration = excluded.duration
            """,
            [
                .text(metadata.id.rawValue),
                SQLiteValue(metadata.kind.rawValue),
                SQLiteValue(metadata.traits.rawValue),
                SQLiteValue(metadata.createdAt),
                SQLiteValue(metadata.modifiedAt),
                SQLiteValue(metadata.pixelWidth),
                SQLiteValue(metadata.pixelHeight),
                SQLiteValue(metadata.coordinate?.latitude),
                SQLiteValue(metadata.coordinate?.longitude),
                SQLiteValue(metadata.isFavorite),
                SQLiteValue(metadata.isHidden),
                SQLiteValue(metadata.duration),
            ]
        )
    }

    func replacePlaceTerms(_ terms: [String], for id: AssetID, in database: SQLiteConnection) throws {
        let joined = terms.filter { !$0.isEmpty }.joined(separator: " ")
        guard !joined.isEmpty else {
            try database.run("DELETE FROM asset_place WHERE asset_id = ?", [.text(id.rawValue)])
            return
        }
        try database.run(
            """
            INSERT INTO asset_place (asset_id, terms) VALUES (?, ?)
            ON CONFLICT(asset_id) DO UPDATE SET terms = excluded.terms
            """,
            [.text(id.rawValue), .text(joined)]
        )
    }

    func apply(_ feature: FeatureRecord, faceWork: inout FaceCommit, in database: SQLiteConnection) throws {
        let id = feature.assetID.rawValue

        switch feature.value {
        case let .embedding(embedding):
            try database.run(
                """
                INSERT INTO embedding (asset_id, model, dimensions, vector)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(asset_id) DO UPDATE SET
                    model = excluded.model,
                    dimensions = excluded.dimensions,
                    vector = excluded.vector
                """,
                [
                    .text(id),
                    .text(embedding.model),
                    SQLiteValue(embedding.dimensions),
                    .blob(VectorBlob.encode(embedding.values)),
                ]
            )

        case let .labels(labels):
            try database.run("DELETE FROM label WHERE asset_id = ?", [.text(id)])
            for label in labels {
                try database.run(
                    """
                    INSERT INTO label (asset_id, identifier, confidence) VALUES (?, ?, ?)
                    ON CONFLICT(asset_id, identifier) DO UPDATE SET confidence = excluded.confidence
                    """,
                    [.text(id), .text(label.identifier), SQLiteValue(Double(label.confidence))]
                )
            }

        case let .text(recognized):
            let geometry = try JSONEncoder().encode(recognized.lines)
            try database.run(
                """
                INSERT INTO recognized_text (asset_id, content, geometry)
                VALUES (?, ?, ?)
                ON CONFLICT(asset_id) DO UPDATE SET
                    content = excluded.content,
                    geometry = excluded.geometry
                """,
                [.text(id), .text(recognized.joined), .blob(geometry)]
            )

        case let .faces(faces):
            try replaceFaces(faces, for: feature.assetID, work: &faceWork, in: database)
        }
    }

    /// Assets whose searchable text may have changed in this batch.
    func searchRowsNeedingRefresh(in batch: IndexBatch) -> Set<AssetID> {
        var ids = Set(batch.metadata.map(\.id))
        for feature in batch.features where feature.stage == .labels || feature.stage == .text {
            ids.insert(feature.assetID)
        }
        return ids
    }

    /// Rebuilds one full-text row from the tables that feed it.
    ///
    /// FTS5 has no upsert, so the row is replaced rather than edited.
    func refreshSearchRow(for id: AssetID, in database: SQLiteConnection) throws {
        try database.run("DELETE FROM asset_search WHERE asset_id = ?", [.text(id.rawValue)])
        try database.run(
            """
            INSERT INTO asset_search (asset_id, content, labels, place)
            VALUES (
                ?1,
                COALESCE((SELECT content FROM recognized_text WHERE asset_id = ?1), ''),
                COALESCE((SELECT group_concat(identifier, ' ') FROM label WHERE asset_id = ?1), ''),
                COALESCE((SELECT terms FROM asset_place WHERE asset_id = ?1), '')
            )
            """,
            [.text(id.rawValue)]
        )
    }
}

// MARK: - Reading

extension SQLiteIndexStore {
    static let assetColumns = """
    a.id, a.kind, a.traits, a.created_at, a.modified_at, a.pixel_width, a.pixel_height,
    a.latitude, a.longitude, a.is_favorite, a.is_hidden, a.duration
    """

    static func decodeAsset(_ row: SQLiteRow) -> AssetMetadata {
        let coordinate: Coordinate? = {
            guard let latitude = row.optionalDouble(7), let longitude = row.optionalDouble(8) else {
                return nil
            }
            return Coordinate(latitude: latitude, longitude: longitude)
        }()

        return AssetMetadata(
            id: AssetID(row.string(0)),
            kind: MediaKind(rawValue: row.int(1)) ?? .unknown,
            traits: MediaTraits(rawValue: row.int(2)),
            createdAt: row.date(3),
            modifiedAt: row.date(4),
            pixelWidth: row.int(5),
            pixelHeight: row.int(6),
            coordinate: coordinate,
            isFavorite: row.bool(9),
            isHidden: row.bool(10),
            duration: row.double(11)
        )
    }

    func requireConnection() throws -> SQLiteConnection {
        guard let connection else {
            throw PicknickError.storeUnavailable("prepare() has not been called")
        }
        return connection
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, count > size else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
