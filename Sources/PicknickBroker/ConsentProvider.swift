import Foundation

public enum ConsentDecision: Hashable, Sendable {
    case approve
    /// Approve only these items; any other item in the preview is dropped.
    case approveRedacted([ContextItem])
    case deny
}

/// The user's review step, usually a sheet showing `renderedText`.
public protocol ConsentProvider: Sendable {
    func approve(_ preview: ContextBundle) async -> ConsentDecision
}
