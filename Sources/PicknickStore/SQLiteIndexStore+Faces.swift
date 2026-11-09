import Foundation
import PicknickCore

/// Face state gathered across one `commit`, so grouping reads every stored
/// face once per batch rather than once per photo.
struct FaceCommit {
    struct KnownFace {
        let id: String
        let assetID: String
        let group: Int
        let fingerprint: [Float]
    }

    var known: [KnownFace]?
    var nextGroup = 1
    var batchFaces: Set<String> = []
    /// A user name was added, moved or removed, so every automatic name may change.
    var namesChanged = false
}

extension SQLiteIndexStore: PersonIndex {
    public func personNames() throws -> [String] {
        let rows = try requireConnection().query(
            "SELECT name FROM face_name UNION SELECT auto_name FROM face WHERE auto_name IS NOT NULL"
        ) { $0.string(0) }
        return Array(Set(rows.map { $0.lowercased() })).sorted()
    }

    public func assets(withAll names: [String], filter: SearchFilter, limit: Int?) throws -> [AssetID] {
        let wanted = Set(names.map(Self.nameKey).filter { !$0.isEmpty })
        guard !wanted.isEmpty, limit.map({ $0 > 0 }) ?? true else { return [] }
        let database = try requireConnection()

        var namesByAsset: [String: Set<String>] = [:]
        _ = try database.query(
            """
            SELECT f.asset_id, COALESCE(n.name, f.auto_name) AS person
            FROM face f LEFT JOIN face_name n ON n.face_id = f.id
            WHERE person IS NOT NULL
            """
        ) { namesByAsset[$0.string(0), default: []].insert(Self.nameKey($0.string(1))) }

        let candidates = Set(namesByAsset.filter { wanted.isSubset(of: $0.value) }.keys)
        guard !candidates.isEmpty else { return [] }

        let (filterSQL, filterBindings) = Self.filterClause(filter)
        let ordered = try database.query(
            """
            SELECT a.id FROM asset a
            WHERE \(filterSQL) AND EXISTS (SELECT 1 FROM face f WHERE f.asset_id = a.id)
            ORDER BY a.created_at DESC, a.id
            """,
            filterBindings
        ) { $0.string(0) }

        var matching: [AssetID] = []
        for id in ordered where candidates.contains(id) {
            if let limit, matching.count >= limit { break }
            matching.append(AssetID(id))
        }
        return matching
    }

    public func faceGroups() throws -> [FaceGroup] {
        let rows = try requireConnection().query(
            """
            SELECT f.id, f.asset_id, f.x, f.y, f.width, f.height, f.group_id,
                   COALESCE(n.name, f.auto_name)
            FROM face f
            JOIN asset a ON a.id = f.asset_id
            LEFT JOIN face_name n ON n.face_id = f.id
            ORDER BY f.group_id, a.created_at DESC, f.id
            """
        ) { row in
            (
                group: row.int(6),
                name: row.optionalString(7),
                face: FaceRef(
                    id: FaceID(rawValue: row.string(0)),
                    assetID: AssetID(row.string(1)),
                    boundingBox: NormalizedRect(x: row.double(2), y: row.double(3), width: row.double(4), height: row.double(5))
                )
            )
        }

        var groups: [FaceGroup] = []
        var start = rows.startIndex
        while start < rows.endIndex {
            let group = rows[start].group
            let end = rows[start...].firstIndex { $0.group != group } ?? rows.endIndex
            let members = rows[start..<end]
            groups.append(FaceGroup(
                id: group,
                name: Self.sharedName(members.compactMap(\.name)),
                photoCount: Set(members.map(\.face.assetID)).count,
                faces: members.map(\.face)
            ))
            start = end
        }
        return groups
    }

    public func nameFace(_ id: FaceID, as name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw PicknickError.storeFailure(operation: "nameFace", message: "empty name")
        }
        let database = try requireConnection()
        try database.transaction {
            let exists = try database.query("SELECT 1 FROM face WHERE id = ?", [.text(id.rawValue)]) { _ in true }
            guard !exists.isEmpty else {
                throw PicknickError.storeFailure(operation: "nameFace", message: "unknown face \(id)")
            }
            try database.run(
                """
                INSERT INTO face_name (face_id, asset_id, x, y, width, height, name)
                SELECT id, asset_id, x, y, width, height, ? FROM face WHERE id = ?
                ON CONFLICT(face_id) DO UPDATE SET name = excluded.name
                """,
                [.text(name), .text(id.rawValue)]
            )
            try recomputeAutomaticNames(only: nil, in: database)
        }
    }

    public func unnameFace(_ id: FaceID) throws {
        let database = try requireConnection()
        try database.transaction {
            try database.run("DELETE FROM face_name WHERE face_id = ?", [.text(id.rawValue)])
            try recomputeAutomaticNames(only: nil, in: database)
        }
    }
}

// MARK: - Writing

extension SQLiteIndexStore {
    func hasUserNames(among ids: [AssetID], in database: SQLiteConnection) throws -> Bool {
        for chunk in ids.chunked(into: Self.bindingChunkSize) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            let found = try database.query(
                "SELECT 1 FROM face_name WHERE asset_id IN (\(placeholders)) LIMIT 1",
                chunk.map { .text($0.rawValue) }
            ) { _ in true }
            if !found.isEmpty { return true }
        }
        return false
    }

    /// Replaces every face of one asset, keeping group ids of faces that kept
    /// their id and moving user names to the new faces (R-13, R-16).
    func replaceFaces(_ faces: [DetectedFace], for asset: AssetID, work: inout FaceCommit, in database: SQLiteConnection) throws {
        if work.known == nil {
            let known = try database.query("SELECT id, asset_id, group_id, fingerprint FROM face") { row in
                FaceCommit.KnownFace(
                    id: row.string(0),
                    assetID: row.string(1),
                    group: row.int(2),
                    fingerprint: Self.decodeFingerprint(row.data(3))
                )
            }
            work.known = known
            work.nextGroup = (known.map(\.group).max() ?? 0) + 1
        }

        let previousGroups = Dictionary(
            work.known!.filter { $0.assetID == asset.rawValue }.map { ($0.id, $0.group) },
            uniquingKeysWith: { first, _ in first }
        )
        work.known!.removeAll { $0.assetID == asset.rawValue }
        try database.run("DELETE FROM face WHERE asset_id = ?", [.text(asset.rawValue)])

        var inserted: [(id: String, box: NormalizedRect)] = []
        for face in faces {
            let id = FaceID(asset: asset, box: face.boundingBox).rawValue
            guard !inserted.contains(where: { $0.id == id }) else { continue }

            let group: Int
            if let previous = previousGroups[id] {
                group = previous
            } else if let nearest = nearestFace(to: face.fingerprint, in: work.known!) {
                group = nearest.group
            } else {
                group = work.nextGroup
                work.nextGroup += 1
            }

            try database.run(
                """
                INSERT INTO face (id, asset_id, x, y, width, height, fingerprint, group_id, auto_name)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL)
                """,
                [
                    .text(id),
                    .text(asset.rawValue),
                    SQLiteValue(face.boundingBox.x),
                    SQLiteValue(face.boundingBox.y),
                    SQLiteValue(face.boundingBox.width),
                    SQLiteValue(face.boundingBox.height),
                    .blob(Self.encodeFingerprint(face.fingerprint)),
                    SQLiteValue(group),
                ]
            )
            work.known!.append(FaceCommit.KnownFace(id: id, assetID: asset.rawValue, group: group, fingerprint: face.fingerprint))
            work.batchFaces.insert(id)
            inserted.append((id, face.boundingBox))
        }

        if try reattachNames(of: asset, to: inserted, in: database) {
            work.namesChanged = true
        }
    }

    func finishFaces(_ work: FaceCommit, in database: SQLiteConnection) throws {
        if work.namesChanged {
            try recomputeAutomaticNames(only: nil, in: database)
        } else if !work.batchFaces.isEmpty {
            try recomputeAutomaticNames(only: work.batchFaces, in: database)
        }
    }
}

private extension SQLiteIndexStore {
    /// Keeps names whose face id survived, moves the rest to the unnamed new
    /// face overlapping most (IoU >= 0.5), and drops names with no such face.
    /// Returns whether the asset had any user names.
    func reattachNames(of asset: AssetID, to faces: [(id: String, box: NormalizedRect)], in database: SQLiteConnection) throws -> Bool {
        let names = try database.query(
            "SELECT face_id, x, y, width, height FROM face_name WHERE asset_id = ? ORDER BY face_id",
            [.text(asset.rawValue)]
        ) { row in
            (id: row.string(0), box: NormalizedRect(x: row.double(1), y: row.double(2), width: row.double(3), height: row.double(4)))
        }
        guard !names.isEmpty else { return false }

        let ids = Set(faces.map(\.id))
        var named = Set(names.map(\.id).filter(ids.contains))

        for name in names where !ids.contains(name.id) {
            let best = faces
                .filter { !named.contains($0.id) }
                .map { (face: $0, overlap: Self.intersectionOverUnion(name.box, $0.box)) }
                .filter { $0.overlap >= 0.5 }
                .max { $0.overlap < $1.overlap }

            if let target = best?.face {
                try database.run(
                    "UPDATE face_name SET face_id = ?, x = ?, y = ?, width = ?, height = ? WHERE face_id = ?",
                    [
                        .text(target.id),
                        SQLiteValue(target.box.x),
                        SQLiteValue(target.box.y),
                        SQLiteValue(target.box.width),
                        SQLiteValue(target.box.height),
                        .text(name.id),
                    ]
                )
                named.insert(target.id)
            } else {
                try database.run("DELETE FROM face_name WHERE face_id = ?", [.text(name.id)])
            }
        }
        return true
    }

    /// Applies R-05 to the faces in `only`, or to every face when nil.
    func recomputeAutomaticNames(only: Set<String>?, in database: SQLiteConnection) throws {
        let named = try database.query(
            "SELECT f.fingerprint, n.name FROM face_name n JOIN face f ON f.id = n.face_id ORDER BY n.face_id"
        ) { (fingerprint: Self.decodeFingerprint($0.data(0)), name: $0.string(1)) }

        let select = """
            SELECT f.id, f.fingerprint, f.auto_name, n.face_id IS NOT NULL
            FROM face f LEFT JOIN face_name n ON n.face_id = f.id
            """
        let decode = { (row: SQLiteRow) in
            (id: row.string(0), fingerprint: Self.decodeFingerprint(row.data(1)), current: row.optionalString(2), hasUserName: row.bool(3))
        }
        let faces = if let only {
            try Array(only).sorted().chunked(into: Self.bindingChunkSize).flatMap { chunk in
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
                return try database.query("\(select) WHERE f.id IN (\(placeholders))", chunk.map(SQLiteValue.text), decode: decode)
            }
        } else {
            try database.query(select, decode: decode)
        }

        for face in faces {
            let automatic = face.hasUserName ? nil : automaticName(for: face.fingerprint, named: named)
            guard automatic != face.current else { continue }
            try database.run(
                "UPDATE face SET auto_name = ? WHERE id = ?",
                [automatic.map(SQLiteValue.text) ?? .null, .text(face.id)]
            )
        }
    }

    /// The name of the nearest user-named face when it is within the cutoff and
    /// every face of another person is at least `rivalGap` of the cutoff farther,
    /// else nil. Depends only on the set of user names, so naming order never
    /// changes it (R-15); the smallest spelling of the name is returned.
    func automaticName(for fingerprint: [Float], named: [(fingerprint: [Float], name: String)]) -> String? {
        var nearest: [String: Double] = [:]
        var spellings: [String: String] = [:]
        for candidate in named {
            let key = Self.nameKey(candidate.name)
            let distance = Double(Self.distance(fingerprint, candidate.fingerprint))
            nearest[key] = Swift.min(nearest[key] ?? .infinity, distance)
            spellings[key] = spellings[key].map { Swift.min($0, candidate.name) } ?? candidate.name
        }
        let ranked = nearest.sorted { ($0.value, $0.key) < ($1.value, $1.key) }
        guard let best = ranked.first, best.value <= faceCutoff else { return nil }
        if ranked.count > 1, ranked[1].value - best.value < faceCutoff * Self.rivalGap { return nil }
        return spellings[best.key]
    }

    func nearestFace(to fingerprint: [Float], in known: [FaceCommit.KnownFace]) -> FaceCommit.KnownFace? {
        var best: (face: FaceCommit.KnownFace, distance: Double)?
        for face in known {
            let distance = Self.distance(fingerprint, face.fingerprint)
            guard distance <= faceCutoff, distance < (best?.distance ?? .infinity) else { continue }
            best = (face, distance)
        }
        return best?.face
    }
}

extension SQLiteIndexStore {
    static func nameKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func sharedName(_ names: [String]) -> String? {
        guard let first = names.first, names.allSatisfy({ nameKey($0) == nameKey(first) }) else { return nil }
        return names.min()
    }

    /// Euclidean distance, the measure `FeaturePrintObservation.distance(to:)`
    /// uses. Fingerprints of different lengths never match.
    static func distance(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        var sum: Double = 0
        for index in a.indices {
            let difference = Double(a[index]) - Double(b[index])
            sum += difference * difference
        }
        return sum.squareRoot()
    }

    static func intersectionOverUnion(_ a: NormalizedRect, _ b: NormalizedRect) -> Double {
        let width = Swift.min(a.x + a.width, b.x + b.width) - Swift.max(a.x, b.x)
        let height = Swift.min(a.y + a.height, b.y + b.height) - Swift.max(a.y, b.y)
        guard width > 0, height > 0 else { return 0 }
        let intersection = width * height
        let union = a.width * a.height + b.width * b.height - intersection
        return union > 0 ? intersection / union : 0
    }

    /// Fingerprints stay `Float32`: unlike CLIP ranking, the naming cutoff is
    /// an absolute distance, and `Float16` rounding would shift it.
    static func encodeFingerprint(_ values: [Float]) -> Data {
        values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func decodeFingerprint(_ data: Data) -> [Float] {
        data.withUnsafeBytes { raw in
            (0..<(data.count / MemoryLayout<Float>.size)).map {
                raw.loadUnaligned(fromByteOffset: $0 * MemoryLayout<Float>.size, as: Float.self)
            }
        }
    }
}
