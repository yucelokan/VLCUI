import Foundation

/// Deliberately NOT a URL-redacting log formatter. Only fixed event names and
/// validated HTTP status numbers may leave this classifier. Unknown messages,
/// URLs, hostnames, response/request headers and error descriptions are dropped.
enum VLCStartupDiagnosticPolicy {
    static func event(for message: String) -> String? {
        let prefix = String(message.prefix(256)).lowercased()
        if prefix.hasPrefix("incoming response:\n") || prefix.hasPrefix("incoming response:\r\n") {
            let lines = prefix.split(whereSeparator: \.isNewline)
            if lines.count > 1 { return httpStatus(in: String(lines[1])) }
            return "http_response_received"
        }
        if prefix.hasPrefix("http answer code ") {
            let number = prefix.dropFirst("http answer code ".count).prefix(3)
            if let code = Int(number), (100...599).contains(code) { return "http_status_\(code)" }
            return nil
        }
        let events: [(String, String)] = [
            ("net: connecting to ", "connection_attempt"),
            ("resolving ", "name_resolution_started"),
            ("cannot resolve ", "name_resolution_failed"),
            ("connection succeeded", "connection_established"),
            ("connection timed out", "connection_timeout"),
            ("connection failed", "connection_failed"),
            ("http connection failure", "http_connection_failed"),
            ("failed to read answer", "http_response_read_failed"),
            ("outgoing request:", "http_request_prepared"),
            ("using access module", "access_module_selected"),
            ("using demux module", "demux_module_selected"),
            ("using audio output module", "audio_output_selected"),
            ("using decoder module", "decoder_selected"),
            ("buffering done", "buffering_complete"),
            ("first pcr received", "clock_reference_received"),
            ("buffer deadlock prevented", "buffer_deadlock_prevented"),
            ("audio output is starving", "audio_output_starved"),
            ("cannot synchronize", "clock_sync_failed"),
            ("cannot start audio output", "audio_output_start_failed"),
            ("no suitable decoder module", "decoder_unavailable"),
            ("dead input", "input_dead"),
        ]
        return events.first { prefix.hasPrefix($0.0) }?.1
    }

    private static func httpStatus(in line: String) -> String? {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 2, ["http/1.0", "http/1.1", "http/2", "http/2.0"].contains(String(fields[0])),
              fields[1].count == 3, let code = Int(fields[1]), (100...599).contains(code) else { return nil }
        return "http_status_\(code)"
    }
}

/// Bounded independently of the number of libVLC worker threads/objects. This
/// observes startup, not every packet/frame, and never drives player recovery.
struct VLCStartupDiagnosticBudget {
    private(set) var epoch = 0
    private var deadline: TimeInterval = 0
    private var emitted = 0
    private var occurrences: [String: Int] = [:]

    mutating func begin(now: TimeInterval) {
        epoch += 1
        deadline = now + 30
        emitted = 0
        occurrences.removeAll(keepingCapacity: true)
    }

    func isRecording(now: TimeInterval) -> Bool { epoch > 0 && now < deadline && emitted < 128 }

    mutating func accept(event: String, objectID: UInt, now: TimeInterval) -> Bool {
        guard isRecording(now: now) else { return false }
        let key = "\(objectID):\(event)"
        let count = occurrences[key, default: 0]
        guard count < 3 else { return false }
        occurrences[key] = count + 1
        emitted += 1
        return true
    }
}
