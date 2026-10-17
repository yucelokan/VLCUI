import Foundation

/// A closed, privacy-safe projection. Shared libVLC callbacks do not identify
/// a player; their startup window is not a playback or attempt identifier.
public struct VLCPlaybackDiagnosticEvent: Equatable, Sendable {
    public enum Scope: String, Sendable { case player, sharedLibrary = "shared_library" }
    public enum Kind: String, Sendable {
        case playerCreated = "player_created", playerError = "player_error"
        case httpStatus = "http_status", httpResponseReceived = "http_response_received"
        case httpRequestPrepared = "http_request_prepared"
        case connectionAttempt = "connection_attempt", connectionEstablished = "connection_established"
        case connectionTimeout = "connection_timeout", connectionFailed = "connection_failed"
        case nameResolutionStarted = "name_resolution_started", nameResolutionFailed = "name_resolution_failed"
        case httpConnectionFailed = "http_connection_failed", httpResponseReadFailed = "http_response_read_failed"
        case accessModuleSelected = "access_module_selected", demuxModuleSelected = "demux_module_selected"
        case audioOutputSelected = "audio_output_selected", decoderSelected = "decoder_selected"
        case bufferingComplete = "buffering_complete", clockReferenceReceived = "clock_reference_received"
        case bufferDeadlockPrevented = "buffer_deadlock_prevented", audioOutputStarved = "audio_output_starved"
        case clockSyncFailed = "clock_sync_failed", audioOutputStartFailed = "audio_output_start_failed"
        case decoderUnavailable = "decoder_unavailable", inputDead = "input_dead"
    }

    public let scope: Scope
    public let kind: Kind
    public let httpStatusCode: Int?
    public let playerID: UUID?
    public let startupWindow: Int?
    public let elapsedMilliseconds: Int

    /// Stable allowlisted identifier, never a raw libVLC message.
    public var event: String {
        kind == .httpStatus ? "http_status_\(httpStatusCode.map(String.init) ?? "unavailable")" : kind.rawValue
    }

    init(scope: Scope, kind: Kind, httpStatusCode: Int? = nil, playerID: UUID? = nil,
         startupWindow: Int? = nil, elapsedMilliseconds: Int = 0) {
        self.scope = scope
        self.kind = kind
        self.httpStatusCode = kind == .httpStatus ? httpStatusCode.flatMap { (100...599).contains($0) ? $0 : nil } : nil
        self.playerID = scope == .player ? playerID : nil
        self.startupWindow = startupWindow
        self.elapsedMilliseconds = max(0, elapsedMilliseconds)
    }

    static func sharedLibrary(event: String, startupWindow: Int) -> Self? {
        if let code = VLCStartupDiagnosticPolicy.httpStatusCode(for: event) {
            return .init(scope: .sharedLibrary, kind: .httpStatus, httpStatusCode: code, startupWindow: startupWindow)
        }
        guard let kind = Kind(rawValue: event), kind != .playerCreated,
              kind != .playerError, kind != .httpStatus else { return nil }
        return .init(scope: .sharedLibrary, kind: kind, startupWindow: startupWindow)
    }
}

/// libVLC's worker must never perform host disk/network logging. The receiver
/// gets only the immutable projection, on a bounded serial delivery queue.
public enum VLCPlaybackDiagnostics {
    private static let delivery = Delivery()

    public static func install(_ receive: (@Sendable (VLCPlaybackDiagnosticEvent) -> Void)?) {
        delivery.install(receive)
    }

    static var isInstalled: Bool { delivery.isInstalled }
    static func emit(_ event: VLCPlaybackDiagnosticEvent) { delivery.enqueue(event) }

    private final class Delivery: @unchecked Sendable {
        private let lock = NSLock()
        private let queue = DispatchQueue(label: "VLCUI.privacy-safe-diagnostics", qos: .utility)
        private var receive: (@Sendable (VLCPlaybackDiagnosticEvent) -> Void)?
        private var pending = 0

        var isInstalled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return receive != nil
        }

        func install(_ receive: (@Sendable (VLCPlaybackDiagnosticEvent) -> Void)?) {
            lock.lock()
            self.receive = receive
            lock.unlock()
        }

        func enqueue(_ event: VLCPlaybackDiagnosticEvent) {
            lock.lock()
            guard let receive, pending < 256 else { lock.unlock(); return }
            pending += 1
            lock.unlock()
            queue.async { [self] in
                receive(event)
                lock.lock()
                pending -= 1
                lock.unlock()
            }
        }
    }
}

/// Created with the concrete player and used only after delegate identity
/// validation. A late retired-player event cannot borrow its replacement's ID.
struct VLCPlayerDiagnosticSession {
    private let playerID: UUID
    private let startedAt: TimeInterval
    private var terminalReported = false

    init(playerID: UUID = UUID(), now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.playerID = playerID
        self.startedAt = now
        VLCPlaybackDiagnostics.emit(.init(scope: .player, kind: .playerCreated, playerID: playerID))
    }

    mutating func reportError(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard !terminalReported else { return }
        terminalReported = true
        VLCPlaybackDiagnostics.emit(.init(scope: .player, kind: .playerError, playerID: playerID,
            elapsedMilliseconds: Int(max(0, now - startedAt) * 1_000)))
    }
}
