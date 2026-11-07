import Foundation

/// What one batch actually achieved.
///
/// The loop needs more than a count of assets touched: a pass that only records
/// failures has consumed work without advancing, and must not be repeated.
public struct BatchOutcome: Hashable, Sendable {
    public var assetsConsidered: Int
    public var stagesCompleted: Int
    public var stagesFailed: Int

    public init(assetsConsidered: Int = 0, stagesCompleted: Int = 0, stagesFailed: Int = 0) {
        self.assetsConsidered = assetsConsidered
        self.stagesCompleted = stagesCompleted
        self.stagesFailed = stagesFailed
    }

    public static let empty = BatchOutcome()

    public var madeProgress: Bool {
        stagesCompleted > 0 || stagesFailed > 0
    }
}
