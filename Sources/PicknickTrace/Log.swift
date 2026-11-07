import Foundation

/// Aligned, line-buffered output for the trace.
enum Log {
    private static let lock = NSLock()

    static func step(_ number: Int, _ title: String) {
        emit("")
        emit("━━ STEP \(number) " + String(repeating: "━", count: max(0, 58 - title.count)) + " \(title)")
        emit("")
    }

    /// One call across a module boundary: what was asked, what came back, and
    /// which protocol the call went through.
    static func call(_ request: String, _ response: String, seam: String) {
        let left = request.padding(toLength: 44, withPad: " ", startingAt: 0)
        let middle = response.padding(toLength: 40, withPad: " ", startingAt: 0)
        emit("   \(left)→ \(middle)\(seam)")
    }

    static func note(_ text: String = "") {
        emit(text.isEmpty ? "" : "   · \(text)")
    }

    static func headline(_ text: String) {
        emit("")
        emit(text)
    }

    private static func emit(_ line: String) {
        lock.withLock { print(line) }
    }
}
