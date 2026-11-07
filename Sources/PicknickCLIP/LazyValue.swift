import Synchronization

/// Builds a value on first use and shares it afterwards.
///
/// The lock is held while loading so concurrent first callers wait for one
/// load instead of each paying for a large model. A failed load is not cached:
/// the host may install the missing file later.
final class LazyValue<Value: Sendable>: Sendable {
    private let load: @Sendable () throws -> Value
    private let state = Mutex<Value?>(nil)

    init(_ load: @escaping @Sendable () throws -> Value) {
        self.load = load
    }

    func get() throws -> Value {
        try state.withLock { cached in
            if let cached { return cached }
            let value = try load()
            cached = value
            return value
        }
    }
}
