import Foundation
import Testing
@testable import PicknickCLIP

/// Fixture vocabulary: 512 byte symbols, then `ca`=512, `cat</w>`=513,
/// `hi</w>`=514, `at</w>`=515, SOT=516, EOT=517.
@Suite("CLIP tokenizer")
struct CLIPTokenizerTests {
    let tokenizer: CLIPTokenizer

    init() throws {
        let url = try #require(Bundle.module.url(forResource: "tiny-merges", withExtension: "txt", subdirectory: "Fixtures"))
        tokenizer = try CLIPTokenizer(mergesURL: url)
    }

    @Test("Special tokens follow the merged vocabulary")
    func specialTokens() {
        #expect(tokenizer.startOfText == 516)
        #expect(tokenizer.endOfText == 517)
    }

    @Test("Lowest-ranked merge is applied first")
    func mergeOrder() {
        #expect(tokenizer.tokenIDs("cat") == [513])
        #expect(tokenizer.tokenIDs("at") == [515])
    }

    @Test("Unmerged symbols fall back to byte tokens")
    func partialMerge() {
        // "cats": ca + t + s</w>; 't' is byte slot 83, "s</w>" is 256 + 82.
        #expect(tokenizer.tokenIDs("cats") == [512, 83, 338])
    }

    @Test("Words, punctuation and digits split apart; text is lowercased")
    func wordSplit() {
        // "," is 256 + 11, "!" is 256 + 0, digits split one per token.
        #expect(tokenizer.tokenIDs("  Hi,\n CAT! ") == [514, 267, 513, 256])
        #expect(tokenizer.tokenIDs("42") == [275, 273])
    }

    @Test("Non-ASCII text is encoded byte by byte")
    func unicodeBytes() {
        // "é" is UTF-8 C3 A9 -> slots 127 and 256 + 102.
        #expect(tokenizer.tokenIDs("é") == [127, 358])
    }

    @Test("Encoding wraps in SOT/EOT and pads to 77")
    func padding() {
        let tokens = tokenizer.encode("cat")
        #expect(tokens.count == 77)
        #expect(Array(tokens.prefix(3)) == [516, 513, 517])
        #expect(tokens.dropFirst(3).allSatisfy { $0 == 0 })
    }

    @Test("Long text is truncated with EOT kept last")
    func truncation() {
        let tokens = tokenizer.encode(Array(repeating: "cat", count: 100).joined(separator: " "))
        #expect(tokens.count == 77)
        #expect(tokens.first == 516)
        #expect(tokens.last == 517)
        #expect(tokens[1..<76].allSatisfy { $0 == 513 })
    }

    @Test("Empty text is just SOT and EOT")
    func empty() {
        #expect(Array(tokenizer.encode("   ").prefix(3)) == [516, 517, 0])
    }

    @Test("Merges beyond the limit are ignored")
    func mergeLimit() throws {
        let limited = try CLIPTokenizer(mergesFile: "#version: 0.2\nc a\nca t</w>\nh i</w>\n", maxMerges: 2)
        #expect(limited.tokenIDs("hi") == [71, 256 + 72])
    }

    @Test("A full-size merges file puts SOT/EOT at 49406/49407 like the reference")
    func referenceSpecialIDs() throws {
        let lines = (0..<CLIPTokenizer.referenceMergeCount + 10).map { "a\($0) b" }
        let full = try CLIPTokenizer(mergesFile: "#version: 0.2\n" + lines.joined(separator: "\n"))
        #expect(full.startOfText == 49406)
        #expect(full.endOfText == 49407)
    }

    @Test("Missing merges file throws vocabularyMissing")
    func missingFile() {
        let url = URL(fileURLWithPath: "/nonexistent/merges.txt")
        #expect(throws: CLIPError.vocabularyMissing(url)) {
            try CLIPTokenizer(mergesURL: url)
        }
    }

    @Test("Malformed merges file throws vocabularyInvalid")
    func malformedFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("picknick-bad-merges-\(UUID().uuidString).txt")
        try "#version: 0.2\nnot-a-pair\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let error = #expect(throws: CLIPError.self) { try CLIPTokenizer(mergesURL: url) }
        guard case .vocabularyInvalid(url, _) = error else {
            Issue.record("expected vocabularyInvalid, got \(String(describing: error))")
            return
        }
        #expect(error?.isModelUnavailable == true)
    }
}
