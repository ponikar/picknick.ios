import Foundation
import PicknickCore
import PicknickStore
import PicknickTestSupport
import Testing

/// Fingerprints are `[v, 0]`, so the distance between two faces is |v1 - v2|.
/// Every test uses a cutoff of 0.5; "within" means distance <= 0.5.
@Suite("Person index")
struct PersonIndexTests {
    private func makeStore(_ batch: IndexBatch) async throws -> SQLiteIndexStore {
        let store = SQLiteIndexStore(path: ":memory:", faceCutoff: 0.5)
        try await store.prepare()
        try await store.commit(batch)
        return store
    }

    private func id(_ asset: AssetID, _ slot: Int = 0) -> FaceID {
        FaceID(asset: asset, box: .face(slot: slot))
    }

    private func named(_ name: String, in store: SQLiteIndexStore) async throws -> Set<AssetID> {
        Set(try await store.assets(withAll: [name], filter: .none, limit: nil))
    }

    private func allFaces(_ store: SQLiteIndexStore) async throws -> [FaceRef] {
        try await store.faceGroups().flatMap(\.faces)
    }

    // R-01
    @Test("R-01: one face record per detected face, with asset and box")
    func storesEveryFace() async throws {
        let groupFaces: [DetectedFace] = (0..<5).map { DetectedFace.fixture(Float($0) * 10, box: .face(slot: $0)) }
        let store = try await makeStore(.photos([(AssetID("group"), groupFaces)]))

        let faces = try await allFaces(store)

        #expect(faces.count == 5)
        #expect(Set(faces.map(\.id)) == Set((0..<5).map { id("group", $0) }))
        #expect(faces.allSatisfy { $0.assetID == "group" })
        #expect(Set(faces.map(\.boundingBox)) == Set((0..<5).map { NormalizedRect.face(slot: $0) }))
    }

    @Test("R-01: two detections with the same rounded box keep only one record")
    func dedupesRoundedBoxes() async throws {
        let box = NormalizedRect.face()
        var nudged = box
        nudged.x += 0.0001
        let store = try await makeStore(.photos([("p", [.fixture(0, box: box), .fixture(9, box: nudged)])]))

        #expect(try await allFaces(store).count == 1)
    }

    // R-02
    @Test("R-02: a photo with no faces stores no faces and completes the face stage")
    func noFaces() async throws {
        let store = try await makeStore(.photos([("empty", [])]))

        #expect(try await allFaces(store).isEmpty)
        let statistics = try await store.statistics(for: [StageRequirement(stage: .faces, version: 1)])
        #expect(statistics.completedByStage[.faces] == 1)
        #expect(try await store.pendingWork([StageRequirement(stage: .faces, version: 1)], retryFailuresBefore: .distantFuture, limit: 10).isEmpty)
    }

    // R-03
    @Test("R-03: groups hold close faces, count distinct photos, and carry the shared name")
    func groups() async throws {
        let store = try await makeStore(.photos([
            ("p1", [.fixture(0)]),
            ("p2", [.fixture(0.3), .fixture(5, box: .face(slot: 1)), .fixture(0.1, box: .face(slot: 2))]),
            ("p3", [.fixture(0.2)]),
        ]))
        try await store.nameFace(id("p1"), as: "darshan")

        let groups = try await store.faceGroups()

        #expect(groups.count == 2)
        let darshan = try #require(groups.first { $0.faces.contains { $0.id == id("p1") } })
        #expect(Set(darshan.faces.map(\.id)) == [id("p1"), id("p2"), id("p2", 2), id("p3")])
        #expect(darshan.photoCount == 3)
        #expect(darshan.name == "darshan")
        let other = try #require(groups.first { $0.faces.contains { $0.id == id("p2", 1) } })
        #expect(other.faces.count == 1)
        #expect(other.photoCount == 1)
        #expect(other.name == nil)
    }

    // R-04, R-05
    @Test("R-04/R-05: naming one face names every face within the cutoff, inclusive")
    func nameSpreadsWithinCutoff() async throws {
        let store = try await makeStore(.photos([
            ("seed", [.fixture(0)]),
            ("near", [.fixture(0.3)]),
            ("edge", [.fixture(0.5)]),
            ("far", [.fixture(0.75)]),
        ]))

        try await store.nameFace(id("seed"), as: "darshan")

        #expect(try await named("darshan", in: store) == ["seed", "near", "edge"])
        #expect(try await store.personNames() == ["darshan"])
    }

    @Test("R-05: names spread by distance to user-named faces, never through automatic names")
    func noTransitiveSpread() async throws {
        let store = try await makeStore(.photos([
            ("seed", [.fixture(0)]),
            ("hop1", [.fixture(0.4)]),
            ("hop2", [.fixture(0.8)]),
        ]))

        try await store.nameFace(id("seed"), as: "darshan")

        #expect(try await named("darshan", in: store) == ["seed", "hop1"])
    }

    @Test("R-05: a face close to two different people stays unnamed")
    func ambiguousStaysUnnamed() async throws {
        let store = try await makeStore(.photos([
            ("alice", [.fixture(0.6)]),
            ("bob", [.fixture(1.4)]),
            ("between", [.fixture(1.0)]),
            ("twoAlices", [.fixture(0.2)]),
            ("alice2", [.fixture(-0.2)]),
        ]))

        try await store.nameFace(id("alice"), as: "alice")
        try await store.nameFace(id("bob"), as: "bob")
        try await store.nameFace(id("alice2"), as: "alice")

        #expect(try await named("alice", in: store) == ["alice", "alice2", "twoAlices"])
        #expect(try await named("bob", in: store) == ["bob"])
    }

    // R-15
    @Test("R-15: naming in a different order gives the same automatic names")
    func orderIndependent() async throws {
        let photos: [(AssetID, [DetectedFace])] = [
            ("a", [.fixture(0)]), ("b", [.fixture(0.8)]),
            ("x", [.fixture(0.4)]), ("y", [.fixture(-0.3)]), ("z", [.fixture(1.2)]),
        ]
        let first = try await makeStore(.photos(photos))
        try await first.nameFace(id("a"), as: "alice")
        try await first.nameFace(id("b"), as: "bob")
        let second = try await makeStore(.photos(photos))
        try await second.nameFace(id("b"), as: "bob")
        try await second.nameFace(id("a"), as: "alice")

        for store in [first, second] {
            #expect(try await named("alice", in: store) == ["a", "y"])
            #expect(try await named("bob", in: store) == ["b", "z"])
        }
    }

    // R-06
    @Test("R-06: renaming one face leaves other user names alone and recomputes automatic ones")
    func rename() async throws {
        let store = try await makeStore(.photos([
            ("f1", [.fixture(0)]),
            ("f2", [.fixture(0.2)]),
            ("auto", [.fixture(-0.4)]),
        ]))
        try await store.nameFace(id("f1"), as: "alice")
        try await store.nameFace(id("f2"), as: "alice")
        #expect(try await named("alice", in: store) == ["f1", "f2", "auto"])

        try await store.nameFace(id("f1"), as: "bob")

        #expect(try await named("bob", in: store) == ["f1", "auto"])
        #expect(try await named("alice", in: store) == ["f2"])
    }

    @Test("R-06: a user name always beats a nearby user name of someone else")
    func userNameWins() async throws {
        let store = try await makeStore(.photos([("f1", [.fixture(0)]), ("f2", [.fixture(0.1)])]))
        try await store.nameFace(id("f2"), as: "carol")
        try await store.nameFace(id("f1"), as: "alice")

        #expect(try await named("alice", in: store) == ["f1"])
        #expect(try await named("carol", in: store) == ["f2"])
    }

    @Test("R-06: unnaming a face lets it fall back to its automatic name")
    func unname() async throws {
        let store = try await makeStore(.photos([("f1", [.fixture(0)]), ("f2", [.fixture(0.2)])]))
        try await store.nameFace(id("f1"), as: "bob")
        try await store.nameFace(id("f2"), as: "alice")

        try await store.unnameFace(id("f1"))

        #expect(try await named("alice", in: store) == ["f1", "f2"])
        #expect(try await named("bob", in: store).isEmpty)
        #expect(try await store.personNames() == ["alice"])
    }

    // R-07 (store level; the indexer test covers the full pipeline)
    @Test("R-07: a face saved after naming is named and grouped in the same commit")
    func newFaceNamedOnCommit() async throws {
        let store = try await makeStore(.photos([("old", [.fixture(0)])]))
        try await store.nameFace(id("old"), as: "darshan")

        try await store.commit(IndexBatch(
            metadata: [.fixture(id: "new")],
            features: [.faces("new", [.fixture(0.25)])]
        ))

        #expect(try await named("darshan", in: store) == ["old", "new"])
        let group = try #require(try await store.faceGroups().first { $0.faces.contains { $0.id == id("old") } })
        #expect(group.faces.contains { $0.id == id("new") })
    }

    // R-13
    @Test("R-13: re-extraction moves user names to the face whose box overlaps by IoU >= 0.5, else drops them")
    func reattachByOverlap() async throws {
        let keptOld = NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        let keptNew = NormalizedRect(x: 0.12, y: 0.1, width: 0.2, height: 0.2)   // IoU 0.82
        let lostOld = NormalizedRect(x: 0.6, y: 0.6, width: 0.2, height: 0.2)
        let lostNew = NormalizedRect(x: 0.7, y: 0.6, width: 0.2, height: 0.2)    // IoU 0.33
        let store = try await makeStore(.photos([
            ("p", [.fixture(0, box: keptOld), .fixture(10, box: lostOld)]),
            ("q", [.fixture(20, box: lostOld)]),
        ]))
        try await store.nameFace(FaceID(asset: "p", box: keptOld), as: "darshan")
        try await store.nameFace(FaceID(asset: "p", box: lostOld), as: "bob")

        try await store.commit(IndexBatch(
            features: [.faces("p", [.fixture(3, box: keptNew), .fixture(13, box: lostNew)])],
            completions: [StageCompletion(assetID: "p", stage: .faces, version: 2)]
        ))

        let faces = try await allFaces(store)
        #expect(Set(faces.filter { $0.assetID == "p" }.map(\.id)) == [FaceID(asset: "p", box: keptNew), FaceID(asset: "p", box: lostNew)])
        #expect(try await named("darshan", in: store) == ["p"])
        #expect(try await named("bob", in: store).isEmpty)
        #expect(try await store.personNames() == ["darshan"])

        try await store.commit(IndexBatch(metadata: [.fixture(id: "r")], features: [.faces("r", [.fixture(3.3)])]))
        #expect(try await named("darshan", in: store) == ["p", "r"])
    }

    // R-16
    @Test("R-16: committing the same faces again keeps ids, rows and user names")
    func reindexIsStable() async throws {
        let photo: [(AssetID, [DetectedFace])] = [("p", [.fixture(0), .fixture(5, box: .face(slot: 1))])]
        let store = try await makeStore(.photos(photo))
        try await store.nameFace(id("p"), as: "darshan")
        let before = try await allFaces(store)

        try await store.commit(.photos(photo))

        let after = try await allFaces(store)
        #expect(after.count == 2)
        #expect(Set(after.map(\.id)) == Set(before.map(\.id)))
        #expect(try await named("darshan", in: store) == ["p"])
        #expect(try await store.personNames() == ["darshan"])
    }

    // R-12 (store level; the indexer test covers library deletion)
    @Test("R-12: removing a photo removes its faces and keeps names on other photos")
    func removalDropsFaces() async throws {
        let store = try await makeStore(.photos([("gone", [.fixture(0)]), ("kept", [.fixture(0.1)])]))
        try await store.nameFace(id("gone"), as: "darshan")
        try await store.nameFace(id("kept"), as: "darshan")

        try await store.commit(IndexBatch(removals: ["gone"]))

        #expect(try await allFaces(store).map(\.assetID) == ["kept"])
        #expect(try await named("darshan", in: store) == ["kept"])
    }

    // R-08, R-11 (store side of person lookup)
    @Test("R-08/R-11: a photo with two named people matches each name and both together")
    func multiPersonLookup() async throws {
        let store = try await makeStore(.photos([
            ("both", [.fixture(0), .fixture(10, box: .face(slot: 1))]),
            ("aliceOnly", [.fixture(0.1)]),
            ("bobOnly", [.fixture(10.1)]),
        ]))
        try await store.nameFace(id("both"), as: "alice")
        try await store.nameFace(id("both", 1), as: "bob")

        #expect(try await named("alice", in: store) == ["both", "aliceOnly"])
        #expect(try await named("bob", in: store) == ["both", "bobOnly"])
        #expect(try await store.assets(withAll: ["alice", "bob"], filter: .none, limit: nil) == ["both"])
        #expect(try await store.assets(withAll: ["alice"], filter: .none, limit: nil) == ["aliceOnly", "both"])
    }
}
