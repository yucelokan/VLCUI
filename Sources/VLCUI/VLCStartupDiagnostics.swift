import Foundation
import VLCKitSPM

/// Shared libVLC logging has NO public player ownership in its callback.
/// Report that scope explicitly, along with emitter/thread IDs; never attribute
/// an outgoing player's HTTP error to the current player or trigger retry here.
final class VLCStartupDiagnostics: NSObject, VLCLogging {
    private static let shared = VLCStartupDiagnostics()
    private let lock = NSLock()
    private var budget = VLCStartupDiagnosticBudget()
    private var networkActivity = VLCStartupNetworkActivityTracker()
    private var emitsLogEvents = false
    var level: VLCLogLevel = .debug

    @MainActor
    @discardableResult
    static func begin(player: VLCMediaPlayer, url: URL, emitsLogEvents: Bool = true) -> Int {
        let library = player.libraryInstance
        // Do not use debugLogging=true: that installs a raw console logger and
        // exposes signed URLs, provider credentials and HTTP headers.
        var loggers = library.loggers ?? []
        if !loggers.contains(where: { ($0 as AnyObject) === shared }) {
            loggers.append(shared)
            library.loggers = loggers
        }
        shared.lock.lock()
        shared.budget.begin(now: ProcessInfo.processInfo.systemUptime)
        shared.networkActivity = VLCStartupNetworkActivityTracker()
        shared.emitsLogEvents = emitsLogEvents
        let epoch = shared.budget.epoch
        shared.lock.unlock()
        if emitsLogEvents {
            let source = url.isFileURL ? "local" : "remote"
            let allowedExtensions = ["m3u8", "mpd", "mkv", "mp4", "ts", "m4v", "mov", "avi"]
            let fileExtension = url.pathExtension.lowercased()
            let containerHint = allowedExtensions.contains(fileExtension) ? fileExtension : "other"
            NSLog("[VLCUI] startup diagnostics epoch=%ld player=%@ source=%@ extension_hint=%@ scope=shared_library uptime_ms=%.0f libvlc=%@",
                  epoch, String(describing: ObjectIdentifier(player)), source, containerHint,
                  ProcessInfo.processInfo.systemUptime * 1000, library.version)
        }
        return epoch
    }

    static func networkActivity(
        epoch: Int,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> VLCStartupNetworkActivity? {
        shared.lock.lock()
        defer { shared.lock.unlock() }
        guard shared.budget.epoch == epoch else { return nil }
        return shared.networkActivity.snapshot(now: now)
    }

    func handleMessage(_ message: String, logLevel: VLCLogLevel, context: VLCLogContext?) {
        // libVLC calls from its worker threads. No main-queue dispatch, player
        // reference, disk/network access, or raw-message retention in this path.
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard budget.isRecording(now: now) else { lock.unlock(); return }
        let observedEpoch = budget.epoch
        lock.unlock()
        guard let event = VLCStartupDiagnosticPolicy.event(for: message) else { return }
        let objectID = context?.objectId ?? 0
        lock.lock()
        // Do not let a classified event race a new startup-window reset.
        let belongsToWindow = budget.epoch == observedEpoch
        if belongsToWindow {
            networkActivity.observe(event: event, now: now)
        }
        let accepted = belongsToWindow && emitsLogEvents
            && budget.accept(event: event, objectID: objectID, now: now)
        lock.unlock()
        guard accepted else { return }
        NSLog("[VLCUI] pipeline epoch=%ld scope=shared_library object=%llu thread=%lu event=%@ uptime_ms=%.0f",
              observedEpoch, UInt64(objectID), context?.threadId ?? 0, event, now * 1000)
    }
}
