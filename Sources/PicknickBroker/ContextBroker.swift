import Foundation
import PicknickCore
import PicknickSearch

/// Turns a remote model's question into user-approved plain text.
///
/// Nothing leaves this type without a `ConsentDecision` other than `.deny`.
/// It never holds pixels, never exposes asset ids and never returns hidden
/// assets. Sending the text is the host app's job; this target has no network
/// code.
public actor ContextBroker {
    public typealias PlaceNamer = @Sendable (Coordinate) async -> String?

    private let engine: SearchEngine
    private let reader: any AssetContextReader
    private let consent: any ConsentProvider
    private let placeName: PlaceNamer?
    private let timeZone: TimeZone

    private var handleMaps: [UUID: [ContextHandle: AssetID]] = [:]

    /// Without `placeName` no place is shared: raw coordinates are more
    /// precise than the user would expect a "place" to be.
    public init(
        engine: SearchEngine,
        reader: any AssetContextReader,
        consent: any ConsentProvider,
        placeName: PlaceNamer? = nil,
        timeZone: TimeZone = .current
    ) {
        self.engine = engine
        self.reader = reader
        self.consent = consent
        self.placeName = placeName
        self.timeZone = timeZone
    }

    /// The approved bundle, or `nil` when the user denies.
    public func context(for request: ContextRequest, options: ContextOptions = .init()) async throws -> ContextBundle? {
        let preview = try await buildPreview(request, options: options)

        let approved: [ContextItem]
        switch await consent.approve(preview.bundle) {
        case .deny:
            return nil
        case .approve:
            approved = preview.bundle.items
        case .approveRedacted(let kept):
            let keptHandles = Set(kept.map(\.handle))
            approved = preview.bundle.items.filter { keptHandles.contains($0.handle) }
        }

        let bundle = ContextBundle(
            id: preview.bundle.id,
            question: preview.bundle.question,
            items: approved,
            timeZone: timeZone
        )
        let approvedHandles = Set(approved.map(\.handle))
        handleMaps[bundle.id] = preview.assets.filter { approvedHandles.contains($0.key) }
        return bundle
    }

    /// Maps a handle from an approved bundle back to its asset, so the app can
    /// show the photos the remote model refers to.
    public func assetID(for handle: ContextHandle, in bundleID: UUID) -> AssetID? {
        handleMaps[bundleID]?[handle]
    }

    public func forget(_ bundleID: UUID) {
        handleMaps[bundleID] = nil
    }

    private func buildPreview(
        _ request: ContextRequest,
        options: ContextOptions
    ) async throws -> (bundle: ContextBundle, assets: [ContextHandle: AssetID]) {
        let limit = max(0, min(request.maxItems, options.maxItems))
        let hits = try await engine.search(SearchQuery(request.question, filter: SearchFilter(includeHidden: false), limit: limit))

        let contexts = try await reader.context(for: hits.map(\.id))
        let byID = Dictionary(contexts.map { ($0.metadata.id, $0) }, uniquingKeysWith: { first, _ in first })

        var items: [ContextItem] = []
        var assets: [ContextHandle: AssetID] = [:]
        for hit in hits {
            // Checked again here because the reader, not the search filter, is
            // the last word on whether an asset is hidden right now.
            guard let context = byID[hit.id], !context.metadata.isHidden else { continue }
            let handle = Self.newHandle(excluding: assets)
            assets[handle] = hit.id
            items.append(await item(for: context, handle: handle, options: options))
        }

        return (ContextBundle(question: request.question, items: items, timeZone: timeZone), assets)
    }

    private func item(for context: AssetContext, handle: ContextHandle, options: ContextOptions) async -> ContextItem {
        let labels = context.labels
            .sorted { $0.confidence != $1.confidence ? $0.confidence > $1.confidence : $0.identifier < $1.identifier }
            .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
        var uniqueLabels: [String] = []
        for label in labels where !uniqueLabels.contains(label) {
            uniqueLabels.append(label)
        }

        var place: String?
        if let placeName, let coordinate = context.metadata.coordinate, coordinate.isValid {
            place = await placeName(coordinate)
        }

        var text: String?
        if options.includeRecognizedText, let recognized = context.text, !recognized.isEmpty {
            text = String(recognized.lines.map(\.content).joined(separator: " ").prefix(max(0, options.maxTextCharacters)))
        }

        return ContextItem(
            handle: handle,
            date: context.metadata.createdAt,
            mediaKind: context.metadata.kind,
            labels: Array(uniqueLabels.prefix(max(0, options.maxLabels))),
            placeText: place,
            recognizedText: text
        )
    }

    /// Random per bundle, so the same photo gets unrelated handles in two
    /// bundles and the remote side cannot link them.
    private static func newHandle(excluding taken: [ContextHandle: AssetID]) -> ContextHandle {
        while true {
            let handle = ContextHandle(rawValue: "p" + UUID().uuidString.prefix(8).lowercased())
            if taken[handle] == nil { return handle }
        }
    }
}
