import Foundation

/// Bounded, monotonic diagnostics belonging to one concrete media player.
/// Seeking and repeated callbacks cannot re-emit a first-output milestone.
struct VLCStartupClock {
    private let startedAt: TimeInterval
    private var observed = Set<String>()

    init(startedAt: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.startedAt = startedAt
    }

    mutating func observe(
        _ milestone: String,
        count: Int,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Int? {
        guard count > 0, observed.insert(milestone).inserted else { return nil }
        return max(0, Int((now - startedAt) * 1000))
    }
}
