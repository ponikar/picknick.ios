import Foundation
import PicknickCore

public enum IndexPhase: Sendable, Hashable {
    case idle
    case scanning
    case writingMetadata
    case extracting
    /// The throttle policy withheld permission; work resumes on the next pass.
    case paused
}

public struct IndexProgress: Sendable, Hashable {
    public var phase: IndexPhase
    public var processedThisRun: Int
    public var statistics: IndexStatistics

    public init(
        phase: IndexPhase = .idle,
        processedThisRun: Int = 0,
        statistics: IndexStatistics = IndexStatistics()
    ) {
        self.phase = phase
        self.processedThisRun = processedThisRun
        self.statistics = statistics
    }
}
