import Foundation
import PicknickCore
@testable import PicknickStore
import Testing

@Suite("Schema migration")
struct MigrationTests {
    @Test("A version 1 database gains place search and keeps its text and labels searchable")
    func migratesFromVersionOne() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("picknick-migration-\(UUID().uuidString).sqlite").path
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: path + suffix)
            }
        }

        do {
            let legacy = try SQLiteConnection(path: path)
            try legacy.transaction {
                try legacy.execute(Schema.migrations[0].statements)
                try legacy.setUserVersion(1)
            }
            try legacy.execute(
                """
                INSERT INTO asset VALUES ('located', 0, 0, 1, 1, 1, 1, 38.72, -9.14, 0, 0, 0);
                INSERT INTO asset VALUES ('unlocated', 0, 0, 2, 2, 1, 1, NULL, NULL, 0, 0, 0);
                INSERT INTO recognized_text VALUES ('unlocated', 'grocery receipt', x'');
                INSERT INTO label VALUES ('located', 'tram', 0.9);
                INSERT INTO asset_search (asset_id, content, labels) VALUES ('unlocated', 'grocery receipt', '');
                INSERT INTO asset_search (asset_id, content, labels) VALUES ('located', '', 'tram');
                """
            )
        }

        let store = SQLiteIndexStore(path: path)
        try await store.prepare()

        #expect(try await store.textMatches(["receipt"], filter: .none, limit: 10).map(\.id) == ["unlocated"])
        #expect(try await store.labelMatches(["tram"], filter: .none, limit: 10).map(\.id) == ["located"])
        #expect(try await store.placeMatches(["lisbon"], filter: .none, limit: 10).isEmpty)

        let fingerprints = try await store.fingerprints()
        #expect(fingerprints["located"]?.modifiedAt == nil)
        #expect(fingerprints["unlocated"]?.modifiedAt != nil)

        try await store.commit(
            IndexBatch(
                metadata: [.init(id: "located", coordinate: Coordinate(latitude: 38.72, longitude: -9.14))],
                placeTerms: ["located": ["Lisbon", "Portugal"]]
            )
        )
        #expect(try await store.placeMatches(["lisbon"], filter: .none, limit: 10).map(\.id) == ["located"])
        #expect(try await store.labelMatches(["tram"], filter: .none, limit: 10).map(\.id) == ["located"])
    }
}
