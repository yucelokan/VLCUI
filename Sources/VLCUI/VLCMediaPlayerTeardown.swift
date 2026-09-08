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
        var completions: [() -> Void] = [] // registryLock only
        var stateObserver: NSObjectProtocol? // retirement queue only
        var didFinish = false // retirement queue only

        init(_ player: VLCMediaPlayer) { self.player = player }
    }

    private static let registryLock = NSLock()
    private static var players: [ObjectIdentifier: Retirement] = [:]
    private static var idleWaiters: [() -> Void] = []
    /// A missing stopped callback must not strand every future player. On this
    /// path releasing the last app-owned reference on the retirement worker is
    /// the fallback gate; any blocking libVLC destruction stays off-main.
    private static let maximumStopAcknowledgementWait: TimeInterval = 2

    /// Runs on the main queue after every already-requested retirement has
    /// released its player. This is opt-in at the configuration level because
    /// VLCUI itself also supports legitimate side-by-side player views.
    static func afterPendingRetirements(_ completion: @escaping () -> Void) {
        registryLock.lock()
        if players.values.contains(where: \.isRetiring) {
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

        // The view and proxy detached this player before retirement. Releasing
        // this final app-owned reference can block inside VLCKit, which is why it
        // deliberately happens on the per-player worker before handover completes.
        retirement.player = nil

        registryLock.lock()
        players.removeValue(forKey: key)
        let completions = retirement.completions
        retirement.completions.removeAll()
        let pendingRetirementsRemain = players.values.contains(where: \.isRetiring)
        let readyWaiters = pendingRetirementsRemain ? [] : idleWaiters
        if !pendingRetirementsRemain { idleWaiters.removeAll() }
        let remaining = players.count
        registryLock.unlock()

        let elapsed = ProcessInfo.processInfo.systemUptime - requestedAt
        NSLog(
            "[VLCUI] retirement completed player=%@ elapsed=%.3fs teardown_ack=%d retained=%d",
            String(describing: key), elapsed, acknowledged ? 1 : 0, remaining
        )
        // Hop once on the worker before notifying the UI. This lets the stop
        // registration block release any temporary strong reference to the
        // Objective-C player before a replacement can be constructed.
        retirement.queue.async {
            DispatchQueue.main.async {
                completions.forEach { $0() }
                readyWaiters.forEach { $0() }
            }
        }
    }
}
