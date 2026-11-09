import Foundation

/// One launch of the host: one round of steps for one side, written by the driver into the app's data container
/// (`Documents/plan.json`, 0600). The host deletes it as soon as it has read it; the driver deletes it too and then
/// removes the app, so the stream addresses never outlive the run.
struct BenchmarkPlan: Decodable {

    enum Action: String, Decodable {
        /// A fresh player: the clock starts when the player view is requested.
        case start
        /// A channel change in the running player: the clock starts at `Proxy.playNewMedia`.
        case next
        case previous
    }

    struct Step: Decodable {
        let alias: String
        let action: Action
        let url: URL
    }

    let version: Int
    let side: String
    let label: String
    let round: Int
    let failAfterSeconds: Double
    let holdSeconds: Double
    let settleSeconds: Double
    let idleBeforeFirstSeconds: Double
    let steps: [Step]
}

/// What the host reports, one JSON object per line in `Documents/results.jsonl`. Aliases, states and numbers only.
enum BenchmarkEvent {

    struct Library: Encodable {
        let event = "library"
        let side: String
        let bundleID: String
        let libvlcVersion: String?
        let libvlcChangeset: String?
        let vlckitVersion: String?
        let idleFootprintBytes: UInt64?
        let options: [String: String]
    }

    struct Sample: Encodable {
        let event = "sample"
        let side: String
        let label: String
        let round: Int
        let alias: String
        let action: String
        /// `ok` (first motion), `error` (VLCUI reported `.error` before first motion) or `timeout` (no motion in time).
        let outcome: String
        let motionMs: Double?
        /// First motion minus the media time reached by then: when the playback clock started.
        let clockStartMs: Double?
        let firstTickMs: Double?
        let firstTickMediaMs: Int?
        let motionMediaMs: Int?
        let playingMs: Double?
        let errorMs: Double?
        /// Buffering states reported during the hold after first motion.
        let bufferingInHold: Int
        let errorInHold: Bool
        /// The longest wall-clock gap between two playhead advances during the hold.
        let maxAdvanceGapMs: Double?
        /// The median interval between playhead callbacks during the hold (each side's own callback cadence).
        let tickIntervalP50Ms: Double?
        let holdMs: Double?
        let footprintSteadyBytes: UInt64?
        let footprintPeakBytes: UInt64?
        let videoWidth: Int?
        let videoHeight: Int?
        /// The engine's own state names (see `EngineState`), and VLCUI's as delivered.
        let states: String
        let vlcuiStates: String
    }

    struct Done: Encodable {
        let event = "done"
        let side: String
        let round: Int
    }

    struct Aborted: Encodable {
        let event = "aborted"
        let reason: String
    }
}

/// Appends events to `Documents/results.jsonl`.
struct EventWriter {

    let url: URL

    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static let standard = EventWriter(url: documents.appendingPathComponent("results.jsonl"))

    func write(_ event: some Encodable) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard var data = try? encoder.encode(event) else { return }
        data.append(0x0A)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
        try? handle.synchronize()
    }
}

enum PlanStore {

    static var url: URL { EventWriter.documents.appendingPathComponent("plan.json") }

    /// Reads the plan and deletes it. Nil when there is none: the app was opened without the driver.
    static func take() throws -> BenchmarkPlan? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)
        return try JSONDecoder().decode(BenchmarkPlan.self, from: data)
    }
}
