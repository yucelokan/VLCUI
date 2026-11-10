import Foundation
import SwiftUI
import UIKit
import VLCUI

/// A player view and its proxy. A new slot is a new `VLCVideoPlayer` (a fresh libVLC player); removing it tears the
/// player down the way each VLCUI revision does on its own.
struct PlayerSlot {
    let id: Int
    let proxy: VLCVideoPlayer.Proxy
    let configuration: VLCVideoPlayer.Configuration
}

/// Runs one plan: each step is timed from its request to first motion, the first playhead advance, on one clock.
@MainActor
final class BenchmarkRunner: ObservableObject {

    @Published
    private(set) var slot: PlayerSlot?
    @Published
    private(set) var status = "Waiting for a plan"

    private let clock = ContinuousClock()
    private let writer = EventWriter.standard
    private let sampler = FootprintSampler()
    private var nextSlotID = 0
    private var attempt: Attempt?
    private var engineGeneration = 3

    /// The observations of one step. Callbacks of another player or another media are never counted.
    private final class Attempt {
        let slotID: Int
        let url: URL
        let requestedAt: ContinuousClock.Instant
        var states: [String] = []
        var vlcuiStates: [String] = []
        var firstTickAt: ContinuousClock.Instant?
        var firstTickMediaMs: Int?
        var motionMediaMs: Int?
        var lastTicks: Int?
        var lastTickAt: ContinuousClock.Instant?
        var motionAt: ContinuousClock.Instant?
        var playingAt: ContinuousClock.Instant?
        var errorAt: ContinuousClock.Instant?
        var lastAdvanceAt: ContinuousClock.Instant?
        var maxAdvanceGap: Duration = .zero
        var tickIntervals: [Duration] = []
        var bufferingInHold = 0
        var errorInHold = false
        var videoSize: CGSize = .zero

        init(slotID: Int, url: URL, requestedAt: ContinuousClock.Instant) {
            self.slotID = slotID
            self.url = url
            self.requestedAt = requestedAt
        }

        var inHold: Bool { motionAt != nil }
    }

    func run() async {
        UIApplication.shared.isIdleTimerDisabled = true
        let plan: BenchmarkPlan
        do {
            guard let taken = try PlanStore.take() else {
                status = "No plan: this app only runs under Benchmark/scripts/vlc_start_benchmark.py"
                return
            }
            plan = taken
        } catch {
            try? FileManager.default.removeItem(at: PlanStore.url)
            writer.write(BenchmarkEvent.Aborted(reason: "unreadable plan"))
            status = "Unreadable plan"
            return
        }

        let library = LibraryInfo.load()
        engineGeneration = library.version?.hasPrefix("4.") == true ? 4 : 3
        writer.write(BenchmarkEvent.Library(
            side: plan.side,
            bundleID: Bundle.main.bundleIdentifier ?? "",
            libvlcVersion: library.version,
            libvlcChangeset: library.changeset,
            vlckitVersion: library.vlckitVersion,
            idleFootprintBytes: Footprint.current(),
            options: AppDefaultOptions.described
        ))
        try? await clock.sleep(for: .seconds(plan.idleBeforeFirstSeconds))

        for step in plan.steps {
            if step.action == .start, slot != nil {
                await tearDown(settle: plan.settleSeconds)
            }
            status = "\(plan.side) \(plan.label) r\(plan.round) \(step.alias) \(step.action.rawValue)"
            let sample = await measure(step, plan: plan)
            writer.write(sample)
        }
        await tearDown(settle: 0)
        writer.write(BenchmarkEvent.Done(side: plan.side, round: plan.round))
        status = "\(plan.side) r\(plan.round) done"
    }

    private func configuration(for url: URL) -> VLCVideoPlayer.Configuration {
        // The shared part of the app's `NAVLCUICompatibilityAdapter.sdkConfiguration`. The fork-only fields
        // (initialVolume, startupNetworkObservationEnabled, serializesInputHandover) do not exist on 4.0.
        VLCVideoPlayer.Configuration(
            url: url,
            autoPlay: true,
            startSeconds: .zero,
            aspectFill: false,
            replay: false,
            rate: .absolute(1),
            subtitleIndex: .auto,
            audioIndex: .auto,
            subtitleSize: .absolute(AppDefaultOptions.subtitleSize),
            subtitleFont: .absolute(AppDefaultOptions.subtitleFont),
            subtitleColor: .absolute(AppDefaultOptions.subtitleColor),
            playbackChildren: [],
            options: AppDefaultOptions.options
        )
    }

    private func measure(_ step: BenchmarkPlan.Step, plan: BenchmarkPlan) async -> BenchmarkEvent.Sample {
        sampler.start()
        let requestedAt: ContinuousClock.Instant
        let current: Attempt
        switch step.action {
        case .start:
            nextSlotID += 1
            requestedAt = clock.now
            current = Attempt(slotID: nextSlotID, url: step.url, requestedAt: requestedAt)
            attempt = current
            slot = PlayerSlot(id: nextSlotID, proxy: VLCVideoPlayer.Proxy(), configuration: configuration(for: step.url))
        case .next, .previous:
            guard let slot else {
                sampler.stop()
                return sample(step, plan: plan, outcome: "error", attempt: nil, holdEnd: nil, steady: nil)
            }
            requestedAt = clock.now
            current = Attempt(slotID: slot.id, url: step.url, requestedAt: requestedAt)
            attempt = current
            slot.proxy.playNewMedia(configuration(for: step.url))
        }

        let deadline = requestedAt.advanced(by: .seconds(plan.failAfterSeconds))
        while current.motionAt == nil, current.errorAt == nil, clock.now < deadline {
            try? await clock.sleep(for: .milliseconds(10))
        }
        guard let motionAt = current.motionAt else {
            attempt = nil
            sampler.stop()
            let outcome = current.errorAt != nil ? "error" : "timeout"
            return sample(step, plan: plan, outcome: outcome, attempt: current, holdEnd: nil, steady: nil)
        }

        // The hold: playback continues while buffering states and playhead gaps are counted.
        try? await clock.sleep(until: motionAt.advanced(by: .seconds(plan.holdSeconds)))
        let holdEnd = clock.now
        if let lastAdvanceAt = current.lastAdvanceAt {
            current.maxAdvanceGap = max(current.maxAdvanceGap, holdEnd - lastAdvanceAt)
        }
        let steady = Footprint.current()
        attempt = nil
        sampler.stop()
        return sample(step, plan: plan, outcome: "ok", attempt: current, holdEnd: holdEnd, steady: steady)
    }

    private func tearDown(settle: Double) async {
        slot = nil
        attempt = nil
        // Each revision stops its player when the view goes (3.7.4: off-main retirement in `dismantleUIView`;
        // 4.0: `stop()` in `deinit`). The settle keeps that teardown out of the next start.
        if settle > 0 {
            try? await clock.sleep(for: .seconds(settle))
        }
    }

    // MARK: - VLCUI callbacks (main thread on both revisions)

    func stateUpdated(_ state: VLCVideoPlayer.State, _ info: VLCVideoPlayer.PlaybackInformation, slot slotID: Int) {
        guard let attempt, attempt.slotID == slotID, info.startConfiguration.url == attempt.url else { return }
        let now = clock.now
        let engineState = EngineState.name(of: state.rawValue, generation: engineGeneration)
        attempt.vlcuiStates.append("\(state)")
        attempt.states.append(engineState)
        switch engineState {
        case "playing":
            if attempt.playingAt == nil { attempt.playingAt = now }
        case "error":
            if attempt.inHold {
                attempt.errorInHold = true
            } else if attempt.errorAt == nil {
                attempt.errorAt = now
            }
        case "buffering":
            if attempt.inHold { attempt.bufferingInHold += 1 }
        default:
            break
        }
    }

    func secondsUpdated(_ seconds: Duration, _ info: VLCVideoPlayer.PlaybackInformation, slot slotID: Int) {
        guard let attempt, attempt.slotID == slotID, info.startConfiguration.url == attempt.url else { return }
        let now = clock.now
        let ticks = Int(seconds.components.seconds * 1000) + Int(seconds.components.attoseconds / 1_000_000_000_000_000)
        if attempt.inHold, let lastTickAt = attempt.lastTickAt {
            attempt.tickIntervals.append(now - lastTickAt)
        }
        if attempt.firstTickAt == nil {
            attempt.firstTickAt = now
            attempt.firstTickMediaMs = ticks
        }
        attempt.lastTickAt = now
        // The app's rule (`NAVLCSessionEngineAdapter.publish`): first motion is the first callback whose time is
        // later than the previous callback's.
        if let previous = attempt.lastTicks, ticks > previous {
            if attempt.motionAt == nil {
                attempt.motionAt = now
                attempt.motionMediaMs = ticks
                attempt.videoSize = info.videoSize
            } else if let lastAdvanceAt = attempt.lastAdvanceAt {
                attempt.maxAdvanceGap = max(attempt.maxAdvanceGap, now - lastAdvanceAt)
            }
            attempt.lastAdvanceAt = now
        }
        attempt.lastTicks = ticks
    }

    // MARK: - Report

    private func sample(
        _ step: BenchmarkPlan.Step,
        plan: BenchmarkPlan,
        outcome: String,
        attempt: Attempt?,
        holdEnd: ContinuousClock.Instant?,
        steady: UInt64?
    ) -> BenchmarkEvent.Sample {
        func ms(_ instant: ContinuousClock.Instant?) -> Double? {
            guard let instant, let attempt else { return nil }
            return Self.milliseconds(instant - attempt.requestedAt)
        }
        let intervals = (attempt?.tickIntervals ?? []).sorted()
        let motionMs = ms(attempt?.motionAt)
        // When the playback clock started: first motion minus the media time it had reached by then. Unlike first
        // motion it does not depend on how often a revision reports the playhead. Kept only when it is plausible
        // (the media time starts near zero and the clock started after the request).
        var clockStartMs: Double?
        if let motionMs, let media = attempt?.motionMediaMs, media >= 0, Double(media) <= motionMs {
            clockStartMs = motionMs - Double(media)
        }
        return BenchmarkEvent.Sample(
            side: plan.side,
            label: plan.label,
            round: plan.round,
            alias: step.alias,
            action: step.action.rawValue,
            outcome: outcome,
            motionMs: motionMs,
            clockStartMs: clockStartMs,
            firstTickMs: ms(attempt?.firstTickAt),
            firstTickMediaMs: attempt?.firstTickMediaMs,
            motionMediaMs: attempt?.motionMediaMs,
            playingMs: ms(attempt?.playingAt),
            errorMs: ms(attempt?.errorAt),
            bufferingInHold: attempt?.bufferingInHold ?? 0,
            errorInHold: attempt?.errorInHold ?? false,
            maxAdvanceGapMs: outcome == "ok" ? attempt.map { Self.milliseconds($0.maxAdvanceGap) } : nil,
            tickIntervalP50Ms: intervals.isEmpty ? nil : Self.milliseconds(intervals[(intervals.count - 1) / 2]),
            holdMs: holdEnd.flatMap { end in attempt?.motionAt.map { Self.milliseconds(end - $0) } },
            footprintSteadyBytes: steady,
            footprintPeakBytes: sampler.peak,
            videoWidth: attempt.map { Int($0.videoSize.width) },
            videoHeight: attempt.map { Int($0.videoSize.height) },
            states: (attempt?.states ?? []).joined(separator: ">"),
            vlcuiStates: (attempt?.vlcuiStates ?? []).joined(separator: ">")
        )
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        let value = Double(components.seconds) * 1000 + Double(components.attoseconds) / 1_000_000_000_000_000
        return (value * 10).rounded() / 10
    }
}
