import Foundation
import VLCKitSPM

/// Each player has a serial worker, so a stalled demux cannot delay another
/// player's stop. Main-queue draining and a grace interval keep ownership away
/// from VLCKit's queued event blocks during release. Arbitrarily late callbacks
/// inside the binary library still require device-level verification.
enum VLCMediaPlayerTeardown {
    private final class Retirement {
        let player: VLCMediaPlayer
        let queue = DispatchQueue(label: "org.vlcui.mediaplayer.retirement", qos: .utility)
        var isRetiring = false // registryLock only

        init(_ player: VLCMediaPlayer) { self.player = player }
    }

    private static let registryLock = NSLock()
    private static var players: [ObjectIdentifier: Retirement] = [:]
    private static let graceInterval: TimeInterval = 1

    static func stop(_ player: VLCMediaPlayer) {
        registryLock.lock()
        defer { registryLock.unlock() }
        let key = ObjectIdentifier(player)
        let retirement = players[key] ?? Retirement(player)
        players[key] = retirement
        guard !retirement.isRetiring else { return }
        retirement.queue.async { retirement.player.stop() }
    }

    static func retire(_ player: VLCMediaPlayer) {
        registryLock.lock()
        defer { registryLock.unlock() }
        let key = ObjectIdentifier(player)
        let retirement = players[key] ?? Retirement(player)
        players[key] = retirement
        guard !retirement.isRetiring else { return }
        retirement.isRetiring = true
        let requestedAt = ProcessInfo.processInfo.systemUptime
        NSLog("[VLCUI] retirement requested player=%@ retained=%d", String(describing: key), players.count)
        retirement.queue.async {
            retirement.player.stop()
            let elapsed = ProcessInfo.processInfo.systemUptime - requestedAt
            NSLog("[VLCUI] stop completed player=%@ elapsed=%.3fs", String(describing: key), elapsed)
            DispatchQueue.main.async {
                retirement.queue.asyncAfter(deadline: .now() + graceInterval) {
                    registryLock.lock()
                    players.removeValue(forKey: key)
                    let remaining = players.count
                    registryLock.unlock()
                    NSLog("[VLCUI] retirement ownership released player=%@ retained=%d", String(describing: key), remaining)
                    // This closure owns retirement until after the lock is
                    // released. A blocking dealloc cannot lock the registry.
                    withExtendedLifetime(retirement) {}
                }
            }
        }
    }
}
