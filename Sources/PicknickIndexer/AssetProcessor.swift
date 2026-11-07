import CoreGraphics
import Foundation
import PicknickCore

/// Runs the outstanding stages for a single asset.
///
/// Stateless and free of any scheduling concern, so the whole per-photo
/// pipeline can be exercised with a fake loader and one metadata value.
struct AssetProcessor: Sendable {
    let imageLoader: any ImageLoader
    let extractors: [any FeatureExtractor]

    func process(_ work: PendingWork) async -> IndexBatch {
        let outstanding = extractors.filter { work.stages.contains($0.stage) }
        guard !outstanding.isEmpty else { return IndexBatch() }

        var batch = IndexBatch()
        var runnable: [any FeatureExtractor] = []

        for extractor in outstanding {
            if extractor.shouldRun(for: work.metadata) {
                runnable.append(extractor)
            } else {
                // A gated-off stage is settled, not skipped: recording it keeps
                // the asset from being picked up again on every future pass.
                batch.completions.append(completion(for: extractor, asset: work.id))
            }
        }

        guard !runnable.isEmpty else { return batch }

        // One decode serves every stage that wants the same resolution, and a
        // stage that needs detail does not force the cheap stages to pay for it.
        let groups = Dictionary(grouping: runnable, by: \.preferredPixelSize)

        for (pixelSize, group) in groups.sorted(by: { $0.key > $1.key }) {
            do {
                let image = try await imageLoader.loadImage(
                    ImageRequest(assetID: work.id, maxPixelSize: pixelSize)
                )
                let context = ExtractionContext(metadata: work.metadata, image: image)
                batch.merge(await run(group, on: context))
            } catch {
                batch.failures.append(contentsOf: group.map {
                    failure(for: $0, asset: work.id, error: error)
                })
            }
        }

        return batch
    }

    private func run(
        _ extractors: [any FeatureExtractor],
        on context: ExtractionContext
    ) async -> IndexBatch {
        var batch = IndexBatch()

        for extractor in extractors.sorted(by: { $0.stage < $1.stage }) {
            do {
                if let value = try await extractor.extract(context) {
                    batch.features.append(FeatureRecord(assetID: context.metadata.id, value: value))
                }
                batch.completions.append(completion(for: extractor, asset: context.metadata.id))
            } catch {
                batch.failures.append(
                    failure(for: extractor, asset: context.metadata.id, error: error)
                )
            }
        }

        return batch
    }

    private func completion(for extractor: any FeatureExtractor, asset: AssetID) -> StageCompletion {
        StageCompletion(assetID: asset, stage: extractor.stage, version: extractor.version)
    }

    private func failure(
        for extractor: any FeatureExtractor,
        asset: AssetID,
        error: any Error
    ) -> StageFailure {
        StageFailure(
            assetID: asset,
            stage: extractor.stage,
            reason: String(describing: error),
            isPermanent: (error as? PicknickError)?.isPermanent ?? false
        )
    }
}
