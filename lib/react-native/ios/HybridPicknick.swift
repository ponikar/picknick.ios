import Foundation
import NitroModules

final class HybridPicknick: HybridPicknickSpec {
    private let service = PicknickService.shared

    func configure(config: PicknickConfig) throws -> Promise<Void> {
        let config = PicknickService.Config(
            imageModel: config.imageModel,
            textModel: config.textModel,
            merges: config.merges,
            cities: config.cities,
            countryInfo: config.countryInfo,
            admin1Codes: config.admin1Codes,
            database: config.database
        )
        return Promise.async { [service] in try await service.configure(config) }
    }

    func requestPhotoAccess() throws -> Promise<PhotoAccess> {
        Promise.async { [service] in
            let access = await service.requestPhotoAccess()
            guard let value = PhotoAccess(fromString: access) else { throw MappingError.unknown(access) }
            return value
        }
    }

    func indexLibrary(onProgress: ((_ status: IndexStatus) -> Void)?) throws -> Promise<IndexStatus> {
        let progress = UncheckedCallback(onProgress)
        return Promise.async { [service] in
            IndexStatus(try await service.indexLibrary { progress.call?(IndexStatus($0)) })
        }
    }

    func getStatus() throws -> Promise<IndexStatus> {
        Promise.async { [service] in IndexStatus(try await service.status()) }
    }

    func search(query: String, options: SearchOptions?) throws -> Promise<[SearchHit]> {
        let topN = options?.topN.map(Int.init) ?? 100
        let minimumProbability = options?.minimumProbability ?? 0
        return Promise.async { [service] in
            try await service.search(query, topN: topN, minimumProbability: minimumProbability).map { hit in
                SearchHit(
                    id: hit.id,
                    uri: "ph://" + hit.id,
                    probability: hit.probability,
                    matchedBy: try hit.matchedBy.map { signal in
                        guard let value = MatchSignal(fromString: signal) else { throw MappingError.unknown(signal) }
                        return value
                    }
                )
            }
        }
    }

    func faceGroups() throws -> Promise<[FaceGroup]> {
        Promise.async { [service] in
            try await service.faceGroups().map { group in
                FaceGroup(
                    id: Double(group.id),
                    name: group.name,
                    photoCount: Double(group.photoCount),
                    faces: group.faces.map { face in
                        FaceRef(
                            faceId: face.id,
                            photoId: face.photoId,
                            uri: "ph://" + face.photoId,
                            box: FaceBox(x: face.x, y: face.y, width: face.width, height: face.height)
                        )
                    }
                )
            }
        }
    }

    func nameFace(faceId: String, name: String) throws -> Promise<Void> {
        Promise.async { [service] in try await service.nameFace(faceId, as: name) }
    }

    func unnameFace(faceId: String) throws -> Promise<Void> {
        Promise.async { [service] in try await service.unnameFace(faceId) }
    }
}

private enum MappingError: LocalizedError {
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .unknown(let value): "Unknown value from PicknickService: \(value)"
        }
    }
}

private struct UncheckedCallback: @unchecked Sendable {
    let call: ((IndexStatus) -> Void)?
    init(_ call: ((IndexStatus) -> Void)?) { self.call = call }
}

private extension IndexStatus {
    init(_ status: PicknickService.Status) {
        self.init(total: Double(status.total), searchable: Double(status.searchable), isIndexing: status.isIndexing)
    }
}
