import Foundation

public struct IndexStatistics: Hashable, Sendable {
    public var totalAssets: Int
    public var completedByStage: [IndexStage: Int]
    public var permanentFailures: Int

    public init(
        totalAssets: Int = 0,
        completedByStage: [IndexStage: Int] = [:],
        permanentFailures: Int = 0
    ) {
        self.totalAssets = totalAssets
        self.completedByStage = completedByStage
        self.permanentFailures = permanentFailures
    }

    /// Share of the library that has cleared a given stage, 0...1.
    public func progress(for stage: IndexStage) -> Double {
        guard totalAssets > 0 else { return 1 }
        return Double(completedByStage[stage] ?? 0) / Double(totalAssets)
    }
}
