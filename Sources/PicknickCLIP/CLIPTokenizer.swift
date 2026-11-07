import Foundation

/// OpenAI CLIP's byte-level BPE tokenizer.
///
/// The vocabulary is derived from the merges file the same way the reference
/// implementation does it (256 byte symbols, the same with `</w>`, one entry
/// per merge, then the two special tokens), so only the merges file is needed.
public struct CLIPTokenizer: Sendable {
    public static let defaultContextLength = 77
    /// The reference tokenizer reads only this many merges from the file.
    public static let referenceMergeCount = 48_894

    public let startOfText: Int32
    public let endOfText: Int32

    private let encoder: [String: Int32]
    private let ranks: [Pair: Int]
    private let byteSymbols: [String]

    private struct Pair: Hashable {
        let first: String
        let second: String
    }

    private static let pattern = try! NSRegularExpression(
        pattern: #"'s|'t|'re|'ve|'m|'ll|'d|\p{L}+|\p{N}|[^\s\p{L}\p{N}]+"#,
        options: [.caseInsensitive]
    )

    public init(mergesURL: URL, maxMerges: Int = referenceMergeCount) throws {
        guard FileManager.default.fileExists(atPath: mergesURL.path) else {
            throw CLIPError.vocabularyMissing(mergesURL)
        }
        let contents: String
        do {
            contents = try String(contentsOf: mergesURL, encoding: .utf8)
        } catch {
            throw CLIPError.vocabularyInvalid(mergesURL, message: String(describing: error))
        }
        do {
            try self.init(mergesFile: contents, maxMerges: maxMerges)
        } catch let message as InvalidMerges {
            throw CLIPError.vocabularyInvalid(mergesURL, message: message.reason)
        }
    }

    init(mergesFile contents: String, maxMerges: Int = referenceMergeCount) throws {
        var lines = contents.split(whereSeparator: \.isNewline)
        if let header = lines.first, header.contains("#version") {
            lines.removeFirst()
        }
        let merges = try lines.prefix(maxMerges).map { line -> Pair in
            let parts = line.split(separator: " ")
            guard parts.count == 2 else {
                throw InvalidMerges(reason: "malformed merge line '\(line)'")
            }
            return Pair(first: String(parts[0]), second: String(parts[1]))
        }
        guard !merges.isEmpty else {
            throw InvalidMerges(reason: "no merges")
        }

        let (symbols, byteSymbols) = Self.byteSymbolTables()
        var vocabulary = symbols + symbols.map { $0 + "</w>" }
        vocabulary += merges.map { $0.first + $0.second }
        vocabulary += ["<|startoftext|>", "<|endoftext|>"]

        // Last occurrence wins on duplicates, as with the reference's dict(zip(...)).
        var encoder: [String: Int32] = [:]
        for (index, token) in vocabulary.enumerated() {
            encoder[token] = Int32(index)
        }
        var ranks: [Pair: Int] = [:]
        for (rank, pair) in merges.enumerated() {
            ranks[pair] = rank
        }

        self.encoder = encoder
        self.ranks = ranks
        self.startOfText = Int32(vocabulary.count - 2)
        self.endOfText = Int32(vocabulary.count - 1)
        self.byteSymbols = byteSymbols
    }

    /// `[SOT] tokens [EOT]`, cut to `contextLength` (keeping EOT last) and
    /// zero-padded to exactly `contextLength`.
    public func encode(_ text: String, contextLength: Int = defaultContextLength) -> [Int32] {
        precondition(contextLength >= 2, "context must fit SOT and EOT")
        let body = tokenIDs(text).prefix(contextLength - 2)
        var tokens = [startOfText] + body + [endOfText]
        tokens += Array(repeating: 0, count: contextLength - tokens.count)
        return tokens
    }

    /// BPE ids for the cleaned text, without SOT/EOT or padding.
    public func tokenIDs(_ text: String) -> [Int32] {
        let cleaned = Self.clean(text)
        let range = NSRange(cleaned.startIndex..., in: cleaned)
        return Self.pattern.matches(in: cleaned, range: range).flatMap { match -> [Int32] in
            let word = String(cleaned[Range(match.range, in: cleaned)!])
            let symbols = word.utf8.map { byteSymbols[Int($0)] }.joined()
            return bpe(symbols).compactMap { encoder[$0] }
        }
    }

    static func clean(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private func bpe(_ token: String) -> [String] {
        var word = token.map(String.init)
        guard !word.isEmpty else { return [] }
        word[word.count - 1] += "</w>"

        while word.count > 1 {
            var best: (rank: Int, pair: Pair)?
            for index in 0..<(word.count - 1) {
                let pair = Pair(first: word[index], second: word[index + 1])
                if let rank = ranks[pair], rank < best?.rank ?? .max {
                    best = (rank, pair)
                }
            }
            guard let pair = best?.pair else { break }

            var merged: [String] = []
            merged.reserveCapacity(word.count)
            var index = 0
            while index < word.count {
                if index < word.count - 1, word[index] == pair.first, word[index + 1] == pair.second {
                    merged.append(pair.first + pair.second)
                    index += 2
                } else {
                    merged.append(word[index])
                    index += 1
                }
            }
            word = merged
        }
        return word
    }

    /// Printable stand-ins for every byte, so BPE never sees whitespace or
    /// control characters. Printable Latin-1 bytes map to themselves and take
    /// the first vocabulary slots; the rest map to U+0100 onwards, in byte order.
    /// Returns symbols by vocabulary slot and by byte value.
    private static func byteSymbolTables() -> (bySlot: [String], byByte: [String]) {
        let printable = Array(33...126) + Array(161...172) + Array(174...255)
        let rest = (0...255).filter { !printable.contains($0) }
        let bytes = printable + rest

        var bySlot: [String] = []
        var byByte = [String](repeating: "", count: 256)
        for (slot, byte) in bytes.enumerated() {
            let scalar = slot < printable.count ? byte : 256 + slot - printable.count
            let symbol = String(UnicodeScalar(UInt32(scalar))!)
            bySlot.append(symbol)
            byByte[byte] = symbol
        }
        return (bySlot, byByte)
    }
}

struct InvalidMerges: Error {
    let reason: String
}
