import Foundation

/// Decides whether the indexer may keep consuming the device.
///
/// Checked between batches rather than within one, so a pause never abandons
/// work that has already been computed.
public protocol ThrottlePolicy: Sendable {
    func permitsWork() -> Bool
}

/// Yields when the device is hot or the user has asked for longer battery life.
public struct DeviceThrottlePolicy: ThrottlePolicy {
    public var pausesWhenHot: Bool
    public var pausesInLowPowerMode: Bool

    public init(pausesWhenHot: Bool = true, pausesInLowPowerMode: Bool = false) {
        self.pausesWhenHot = pausesWhenHot
        self.pausesInLowPowerMode = pausesInLowPowerMode
    }

    public func permitsWork() -> Bool {
        let info = ProcessInfo.processInfo

        if pausesWhenHot {
            switch info.thermalState {
            case .serious, .critical: return false
            case .nominal, .fair: break
            @unknown default: break
            }
        }

        if pausesInLowPowerMode, info.isLowPowerModeEnabled {
            return false
        }

        return true
    }
}

public struct UnthrottledPolicy: ThrottlePolicy {
    public init() {}
    public func permitsWork() -> Bool { true }
}
