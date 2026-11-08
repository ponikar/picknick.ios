import Foundation

/// People named by the user, read fresh on every call so a new name is
/// searchable without rebuilding anything.
public protocol PersonIndex: Sendable {
    /// Every user or automatic person name, lowercased.
    func personNames() async throws -> [String]

    /// Assets containing a face of every person in `names`, newest first.
    func assets(withAll names: [String], filter: SearchFilter, limit: Int?) async throws -> [AssetID]

    func faceGroups() async throws -> [FaceGroup]

    /// Stores `name` as the user name of one face, then recomputes automatic names.
    func nameFace(_ id: FaceID, as name: String) async throws

    func unnameFace(_ id: FaceID) async throws
}
