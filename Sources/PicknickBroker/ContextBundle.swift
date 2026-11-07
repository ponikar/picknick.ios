import Foundation
import PicknickCore

/// A question from the remote model. Everything here is untrusted input.
public struct ContextRequest: Hashable, Sendable {
    public var question: String
    public var maxItems: Int

    public init(question: String, maxItems: Int) {
        self.question = question
        self.maxItems = maxItems
    }
}

/// Choices only the user makes; never derived from a `ContextRequest`.
public struct ContextOptions: Hashable, Sendable {
    /// Recognized text can carry addresses, names or numbers, so it is off
    /// unless the user turns it on for this request.
    public var includeRecognizedText: Bool
    public var maxItems: Int
    public var maxLabels: Int
    public var maxTextCharacters: Int

    public init(includeRecognizedText: Bool = false, maxItems: Int = 20, maxLabels: Int = 3, maxTextCharacters: Int = 200) {
        self.includeRecognizedText = includeRecognizedText
        self.maxItems = maxItems
        self.maxLabels = maxLabels
        self.maxTextCharacters = maxTextCharacters
    }
}

/// Stands in for an asset inside one bundle. It carries no asset id; only the
/// broker that issued it can map it back.
public struct ContextHandle: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public struct ContextItem: Hashable, Sendable {
    public let handle: ContextHandle
    public let date: Date?
    public let mediaKind: MediaKind
    public let labels: [String]
    public let placeText: String?
    public let recognizedText: String?

    public init(
        handle: ContextHandle,
        date: Date?,
        mediaKind: MediaKind,
        labels: [String],
        placeText: String? = nil,
        recognizedText: String? = nil
    ) {
        self.handle = handle
        self.date = date
        self.mediaKind = mediaKind
        self.labels = labels
        self.placeText = placeText
        self.recognizedText = recognizedText
    }
}

public struct ContextBundle: Hashable, Sendable, Identifiable {
    public let id: UUID
    public let question: String
    public let items: [ContextItem]
    /// Dates render as calendar days in this zone, so the text does not
    /// depend on the device the bundle is rendered on.
    public let timeZone: TimeZone

    public init(id: UUID = UUID(), question: String, items: [ContextItem], timeZone: TimeZone) {
        self.id = id
        self.question = question
        self.items = items
        self.timeZone = timeZone
    }

    /// The exact text the user approves and the host app sends.
    public var renderedText: String {
        var lines = ["Question: \(Self.singleLine(question))", "Photos: \(items.count)"]
        for item in items {
            var fields = [item.date.map(day) ?? "unknown date", Self.name(of: item.mediaKind)]
            if !item.labels.isEmpty {
                fields.append("labels: " + item.labels.map(Self.singleLine).joined(separator: ", "))
            }
            if let place = item.placeText {
                fields.append("place: \(Self.singleLine(place))")
            }
            lines.append("[\(item.handle)] " + fields.joined(separator: " | "))
            if let text = item.recognizedText {
                lines.append("  text: \(Self.singleLine(text))")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func day(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static func name(of kind: MediaKind) -> String {
        switch kind {
        case .image: "photo"
        case .video: "video"
        case .unknown: "media"
        }
    }

    /// Keeps every value on its own line so untrusted text (the question,
    /// recognized text) cannot fake extra items in the rendered output.
    private static func singleLine(_ value: String) -> String {
        value.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
