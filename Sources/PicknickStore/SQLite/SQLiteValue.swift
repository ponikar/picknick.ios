import Foundation

public enum SQLiteValue: Hashable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

extension SQLiteValue {
    init(_ value: Int) { self = .integer(Int64(value)) }
    init(_ value: Bool) { self = .integer(value ? 1 : 0) }
    init(_ value: Double) { self = .real(value) }
    init(_ value: String) { self = .text(value) }
    init(_ value: Data) { self = .blob(value) }

    init(_ value: Date?) {
        self = value.map { .real($0.timeIntervalSinceReferenceDate) } ?? .null
    }

    init(_ value: Double?) {
        self = value.map { .real($0) } ?? .null
    }
}

extension SQLiteValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .text(value) }
}

extension SQLiteValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .integer(Int64(value)) }
}
