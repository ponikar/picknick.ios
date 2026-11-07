import Foundation
import PicknickCore
import Photos

extension AssetMetadata {
    init(_ asset: PHAsset) {
        self.init(
            id: AssetID(asset.localIdentifier),
            kind: MediaKind(asset.mediaType),
            traits: MediaTraits(asset),
            createdAt: asset.creationDate,
            modifiedAt: asset.modificationDate,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            coordinate: asset.location.map {
                Coordinate(
                    latitude: $0.coordinate.latitude,
                    longitude: $0.coordinate.longitude
                )
            },
            isFavorite: asset.isFavorite,
            isHidden: asset.isHidden,
            duration: asset.duration
        )
    }
}

extension MediaKind {
    init(_ mediaType: PHAssetMediaType) {
        self = switch mediaType {
        case .image: .image
        case .video: .video
        default: .unknown
        }
    }
}

extension MediaTraits {
    init(_ asset: PHAsset) {
        var traits: MediaTraits = []
        let subtypes = asset.mediaSubtypes

        if subtypes.contains(.photoScreenshot) { traits.insert(.screenshot) }
        if subtypes.contains(.photoLive) { traits.insert(.livePhoto) }
        if subtypes.contains(.photoPanorama) { traits.insert(.panorama) }
        if subtypes.contains(.photoHDR) { traits.insert(.highDynamicRange) }
        if subtypes.contains(.photoDepthEffect) { traits.insert(.depthEffect) }
        if subtypes.contains(.videoTimelapse) { traits.insert(.timelapse) }
        if subtypes.contains(.videoHighFrameRate) { traits.insert(.slowMotion) }
        if subtypes.contains(.videoCinematic) { traits.insert(.cinematic) }
        if subtypes.contains(.videoScreenRecording) { traits.insert(.screenRecording) }
        if subtypes.contains(.spatialMedia) { traits.insert(.spatial) }
        if asset.representsBurst { traits.insert(.burst) }

        self = traits
    }
}

extension LibraryAuthorization {
    init(_ status: PHAuthorizationStatus) {
        self = switch status {
        case .authorized: .authorized
        case .limited: .limited
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }
}
