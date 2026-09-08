import Foundation
import VLCKitSPM

/// Retires VLC players away from the UI thread and reports when the outgoing
/// player can no longer own an input. VLCKit 3.7.2 maps `stop()` to libVLC's
/// asynchronous stop API, so returning from that call is not a handover gate.
enum VLCMediaPlayerTeardown {
    private final class Retirement {
        var player: VLCMediaPlayer?
        let queue = DispatchQueue(label: "org.vlcui.mediaplayer.retirement", qos: .utility)
        var isRetiring = false // registryLock only
        var isHandoverReady = false // registryLock only
        var completions: [() -> Void] = [] // registryLock only
        var stateObserver: NSObjectProtocol? // retirement queue only
        var didFinish = false // retirement queue only

        init(_ player: VLCMediaPlayer) { self.player = player }
    }

    private static let registryLock = NSLock()
    private static var players: [ObjectIdentifier: Retirement] = [:]
    private static var idleWaiters: [() -> Void] = []
    /// A missing stopped callback must not strand every future player. This
    /// fallback opens the handover gate; final release still follows the
    /// off-main event-drain quarantine below.
    private static let maximumStopAcknowledgementWait: TimeInterval = 2
    /// VLCKit delivers state changes through main-queue blocks that retain the
    /// Objective-C player wrapper. Keep our final reference past a main-queue
    /// drain and a grace interval, then release it on the retirement worker.
    /// This quarantine does not delay input handover or replacement playback.
    private static let queuedEventDrainGrace: TimeInterval = 1

    /// Runs on the main queue after every already-requested retirement reaches
    /// its stopped-or-timeout handover gate. Final wrapper release is quarantined
    /// independently because VLCUI also supports fast replacement playback.
    static func afterPendingRetirements(_ completion: @escaping () -> Void) {
        registryLock.lock()
        if hasPendingHandover {
            idleWaiters.append(completion)
            registryLock.unlock()
        } else {
            registryLock.unlock()
            DispatchQueue.main.async(execute: completion)
        }
    }

    static func stop(_ player: VLCMediaPlayer) {
        registryLock.lock()
        let key = ObjectIdentifier(player)
        let retirement = players[key] ?? Retirement(player)
        players[key] = retirement
        let isRetiring = retirement.isRetiring
        registryLock.unlock()
        guard !isRetiring else { return }

        retirement.queue.async {
            retirement.player?.stop()
            registryLock.lock()
            if !retirement.isRetiring { players.removeValue(forKey: key) }
            registryLock.unlock()
        }
    }

    static func retire(_ player: VLCMediaPlayer, completion: @escaping () -> Void = {}) {
        registryLock.lock()
        let key = ObjectIdentifier(player)
        let retirement = players[key] ?? Retirement(player)
        players[key] = retirement
        if retirement.isHandoverReady {
            registryLock.unlock()
            DispatchQueue.main.async(execute: completion)
            return
        }
        retirement.completions.append(completion)
        guard !retirement.isRetiring else {
            registryLock.unlock()
            return
        }
        retirement.isRetiring = true
        let retainedCount = players.count
        registryLock.unlock()

        let requestedAt = ProcessInfo.processInfo.systemUptime
        NSLog("[VLCUI] retirement requested player=%@ retained=%d", String(describing: key), retainedCount)
        retirement.queue.async {
            let center = NotificationCenter.default
            retirement.stateObserver = center.addObserver(
                forName: Notification.Name(VLCMediaPlayerStateChanged),
                object: player,
                queue: nil
            ) { notification in
                guard let notifiedPlayer = notification.object as? VLCMediaPlayer,
                      ObjectIdentifier(notifiedPlayer) == key,
                      notifiedPlayer.state == .stopped else { return }
                retirement.queue.async {
                    finish(retirement, key: key, requestedAt: requestedAt, acknowledged: true)
                }
            }

            retirement.player?.stop()
            let elapsed = ProcessInfo.processInfo.systemUptime - requestedAt
            NSLog("[VLCUI] stop call returned player=%@ elapsed=%.3fs teardown_ack=false", String(describing: key), elapsed)

            if retirement.player?.state == .stopped {
                finish(retirement, key: key, requestedAt: requestedAt, acknowledged: true)
                return
            }

            retirement.queue.asyncAfter(deadline: .now() + maximumStopAcknowledgementWait) {
                finish(retirement, key: key, requestedAt: requestedAt, acknowledged: false)
            }
        }
    }

    private static func finish(
        _ retirement: Retirement,
        key: ObjectIdentifier,
        requestedAt: TimeInterval,
        acknowledged: Bool
    ) {
        dispatchPrecondition(condition: .onQueue(retirement.queue))
        guard !retirement.didFinish else { return }
        retirement.didFinish = true

        if let observer = retirement.stateObserver {
            NotificationCenter.default.removeObserver(observer)
            retirement.stateObserver = nil
        }

        registryLock.lock()
        retirement.isHandoverReady = true
        let completions = retirement.completions
        retirement.completions.removeAll()
        let pendingRetirementsRemain = hasPendingHandover
        let readyWaiters = pendingRetirementsRemain ? [] : idleWaiters
        if !pendingRetirementsRemain { idleWaiters.removeAll() }
        let retained = players.count
        registryLock.unlock()

        let elapsed = ProcessInfo.processInfo.systemUptime - requestedAt
        NSLog(
            "[VLCUI] retirement handover ready player=%@ elapsed=%.3fs teardown_ack=%d retained=%d",
            String(describing: key), elapsed, acknowledged ? 1 : 0, retained
        )
        // Hop once on the worker so the stop-registration block releases its
        // temporary player reference before the first main-queue drain marker.
        retirement.queue.async {
            DispatchQueue.main.async {
                completions.forEach { $0() }
                deliverIdleWaitersWhenReady(readyWaiters)

                // This first main hop drains VLCKit events queued by stop. The
                // grace absorbs stragglers, and the second hop drains those too.
                retirement.queue.asyncAfter(deadline: .now() + queuedEventDrainGrace) {
                    DispatchQueue.main.async {
                        retirement.queue.async {
                            releaseAfterEventDrain(retirement, key: key, requestedAt: requestedAt)
                        }
                    }
                }
            }
        }
    }

    /// Must be evaluated while `registryLock` is held.
    private static var hasPendingHandover: Bool {
        players.values.contains { $0.isRetiring && !$0.isHandoverReady }
    }

    private static func deliverIdleWaitersWhenReady(_ waiters: [() -> Void]) {
        guard !waiters.isEmpty else { return }
        dispatchPrecondition(condition: .onQueue(.main))
        registryLock.lock()
        if hasPendingHandover {
            idleWaiters.append(contentsOf: waiters)
            registryLock.unlock()
        } else {
            registryLock.unlock()
            waiters.forEach { $0() }
        }
    }

    private static func releaseAfterEventDrain(
        _ retirement: Retirement,
        key: ObjectIdentifier,
        requestedAt: TimeInterval
    ) {
        dispatchPrecondition(condition: .onQueue(retirement.queue))

        // If this is the final reference, blocking libVLC destruction happens
        // here on the per-player worker. Main-queue event blocks have already
        // been drained twice while this reference kept the wrapper alive.
        retirement.player = nil

        registryLock.lock()
        if players[key] === retirement { players.removeValue(forKey: key) }
        let retained = players.count
        registryLock.unlock()

        let elapsed = ProcessInfo.processInfo.systemUptime - requestedAt
        NSLog(
            "[VLCUI] retirement ownership released player=%@ elapsed=%.3fs retained=%d",
            String(describing: key), elapsed, retained
        )
    }
}
