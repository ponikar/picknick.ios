import Foundation
import PicknickCore
import Testing

@Suite("Library diff")
struct LibraryDiffTests {
    private func fingerprint(_ seconds: Double) -> AssetFingerprint {
        AssetFingerprint(modifiedAt: Date(timeIntervalSinceReferenceDate: seconds))
    }

    @Test("An empty index reports every asset as inserted")
    func emptyIndex() {
        let delta = LibraryDiff.compute(
            library: ["a": fingerprint(10), "b": fingerprint(20)],
            index: [:]
        )

        #expect(delta.inserted == ["a", "b"])
        #expect(delta.updated.isEmpty)
        #expect(delta.removed.isEmpty)
    }

    @Test("A matching fingerprint produces no work")
    func unchanged() {
        let shared: [AssetID: AssetFingerprint] = ["a": fingerprint(10)]
        #expect(LibraryDiff.compute(library: shared, index: shared).isEmpty)
    }

    @Test("A newer modification date marks the asset updated")
    func edited() {
        let delta = LibraryDiff.compute(
            library: ["a": fingerprint(20)],
            index: ["a": fingerprint(10)]
        )

        #expect(delta.updated == ["a"])
        #expect(delta.inserted.isEmpty)
    }

    @Test("An asset missing from the library is removed")
    func deleted() {
        let delta = LibraryDiff.compute(
            library: [:],
            index: ["a": fingerprint(10)]
        )

        #expect(delta.removed == ["a"])
    }

    @Test("Sub-millisecond drift in stored dates is not an edit")
    func toleratesStorageDrift() {
        let delta = LibraryDiff.compute(
            library: ["a": fingerprint(10.0000001)],
            index: ["a": fingerprint(10)]
        )

        #expect(delta.isEmpty)
    }

    @Test("An asset that gained a modification date counts as updated")
    func gainedDate() {
        let delta = LibraryDiff.compute(
            library: ["a": fingerprint(10)],
            index: ["a": AssetFingerprint(modifiedAt: nil)]
        )

        #expect(delta.updated == ["a"])
    }
}
