import Foundation
import PicknickCLIP
import PicknickCore
import PicknickIndexer
import PicknickPhotos
import PicknickPlaces
import PicknickSearch
import PicknickStore
import PicknickVision

actor PicknickService {
    struct Config: Sendable {
        var imageModel: String
        var textModel: String
        var merges: String
        var cities: String?
        var countryInfo: String?
        var admin1Codes: String?
        var database: String?
    }

    struct Status: Sendable {
        var total: Int
        var searchable: Int
        var isIndexing: Bool
    }

    struct Hit: Sendable {
        var id: String
        var probability: Double
        var matchedBy: [String]
    }

    struct Face: Sendable {
        var id: String
        var photoId: String
        var x: Double
        var y: Double
        var width: Double
        var height: Double
    }

    struct Group: Sendable {
        var id: Int
        var name: String?
        var photoCount: Int
        var faces: [Face]
    }

    enum ServiceError: LocalizedError {
        case notConfigured
        case alreadyIndexing
        case missingFile(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: "Call configure() first."
            case .alreadyIndexing: "Indexing is already running."
            case .missingFile(let path): "File not found: \(path)"
            }
        }
    }

    static let shared = PicknickService()

    private let library = PhotoKitLibrary()
    private var store: SQLiteIndexStore?
    private var coordinator: IndexCoordinator?
    private var engine: SearchEngine?
    private var isIndexing = false

    func configure(_ config: Config) throws {
        let gazetteer = try config.cities.map { cities in
            try Gazetteer(
                citiesURL: try Self.resolve(cities),
                countryInfoURL: try config.countryInfo.map(Self.resolve),
                admin1CodesURL: try config.admin1Codes.map(Self.resolve)
            )
        }
        let store = SQLiteIndexStore(path: try Self.databaseURL(config.database).path)

        coordinator = IndexCoordinator(
            library: library,
            store: store,
            imageLoader: PhotoKitImageLoader(),
            extractors: [
                CLIPImageExtractor(modelURL: try Self.resolve(config.imageModel)),
                VisionLabelExtractor(),
                VisionTextExtractor(),
                VisionFaceExtractor(),
            ],
            placeNaming: gazetteer.map { PlaceResolver(gazetteer: $0) }
        )
        engine = SearchEngine(
            index: store,
            embedder: CLIPTextEmbedder(
                modelURL: try Self.resolve(config.textModel),
                mergesURL: try Self.resolve(config.merges)
            ),
            placeVocabulary: gazetteer.map { PlaceNameIndex(gazetteer: $0) },
            people: store
        )
        self.store = store
    }

    func requestPhotoAccess() async -> String {
        switch await library.requestAuthorization() {
        case .authorized: "authorized"
        case .limited: "limited"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "notDetermined"
        }
    }

    func indexLibrary(onProgress: @escaping @Sendable (Status) -> Void) async throws -> Status {
        guard let coordinator else { throw ServiceError.notConfigured }
        guard !isIndexing else { throw ServiceError.alreadyIndexing }
        isIndexing = true
        defer { isIndexing = false }

        try await coordinator.synchronize()
        onProgress(try await status())
        while try await coordinator.processNextBatch().madeProgress {
            onProgress(try await status())
        }
        isIndexing = false
        return try await status()
    }

    func status() async throws -> Status {
        guard let coordinator else { throw ServiceError.notConfigured }
        let statistics = try await coordinator.statistics()
        return Status(
            total: statistics.totalAssets,
            searchable: statistics.completedByStage[.embedding] ?? 0,
            isIndexing: isIndexing
        )
    }

    func search(_ query: String, topN: Int, minimumProbability: Double) async throws -> [Hit] {
        guard let engine else { throw ServiceError.notConfigured }
        let results = try await engine.search(SearchQuery(query, limit: topN, minimumProbability: minimumProbability))
        return results.map { result in
            Hit(
                id: result.id.rawValue,
                probability: result.score,
                matchedBy: result.ranks.sorted { $0.value < $1.value }.map(\.key.rawValue)
            )
        }
    }

    func faceGroups() async throws -> [Group] {
        guard let store else { throw ServiceError.notConfigured }
        return try await store.faceGroups().map { group in
            Group(
                id: group.id,
                name: group.name,
                photoCount: group.photoCount,
                faces: group.faces.map { face in
                    Face(
                        id: face.id.rawValue,
                        photoId: face.assetID.rawValue,
                        x: face.boundingBox.x,
                        y: face.boundingBox.y,
                        width: face.boundingBox.width,
                        height: face.boundingBox.height
                    )
                }
            )
        }
    }

    func nameFace(_ faceId: String, as name: String) async throws {
        guard let store else { throw ServiceError.notConfigured }
        try await store.nameFace(FaceID(rawValue: faceId), as: name)
    }

    func unnameFace(_ faceId: String) async throws {
        guard let store else { throw ServiceError.notConfigured }
        try await store.unnameFace(FaceID(rawValue: faceId))
    }

    /// Absolute paths are used as given; bare names are looked up in the app bundle.
    private static func resolve(_ path: String) throws -> URL {
        let url = path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : Bundle.main.resourceURL?.appending(path: path)
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            throw ServiceError.missingFile(path)
        }
        return url
    }

    private static func databaseURL(_ path: String?) throws -> URL {
        if let path { return URL(fileURLWithPath: path) }
        let directory = URL.applicationSupportDirectory.appending(path: "Picknick")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "index.sqlite")
    }
}
