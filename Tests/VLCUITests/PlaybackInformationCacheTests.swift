import Foundation
import XCTest
@testable import VLCUI

final class PlaybackInformationCacheTests: XCTestCase {
    func testCacheRejectsSnapshotFromRetiredGeneration() {
        let configuration = VLCVideoPlayer.Configuration(url: URL(string: "https://example.com/live")!)
        var cache = VLCVideoPlayer.PlaybackInformationCache()
        cache.reset(configuration: configuration, generation: 2)

        let stale = makeInformation(configuration: configuration, generation: 1, audioIndex: 7)

        XCTAssertFalse(cache.apply(stale, generation: 1))
        XCTAssertEqual(cache.information?.sessionGeneration, 2)
        XCTAssertTrue(cache.information?.audioTracks.isEmpty == true)
    }

    func testResetInvalidatesPreviousSessionDetailsAndStatistics() {
        let configuration = VLCVideoPlayer.Configuration(url: URL(string: "https://example.com/live")!)
        var cache = VLCVideoPlayer.PlaybackInformationCache()
        cache.reset(configuration: configuration, generation: 1)
        XCTAssertTrue(cache.apply(makeInformation(configuration: configuration, generation: 1, audioIndex: 4), generation: 1))

        cache.reset(configuration: configuration, generation: 2)

        XCTAssertEqual(cache.information?.sessionGeneration, 2)
        XCTAssertTrue(cache.information?.audioTracks.isEmpty == true)
        XCTAssertEqual(cache.information?.statistics.readBytes, 0)
    }

    func testSnapshotGateBoundsAndPromotesPendingDetailRead() {
        var gate = VLCVideoPlayer.PlaybackSnapshotGate()

        XCTAssertEqual(gate.request(.statistics, generation: 7), .statistics)
        XCTAssertNil(gate.request(.statistics, generation: 7))
        XCTAssertNil(gate.request(.details, generation: 7))
        XCTAssertNil(gate.request(.statistics, generation: 7))
        XCTAssertEqual(gate.complete(generation: 7), .details)
        XCTAssertEqual(gate.request(.details, generation: 7), .details)
    }

    func testSnapshotGateRejectsRetiredCompletion() {
        var gate = VLCVideoPlayer.PlaybackSnapshotGate()
        XCTAssertEqual(gate.request(.details, generation: 10), .details)
        gate.invalidate()
        XCTAssertEqual(gate.request(.statistics, generation: 11), .statistics)
        XCTAssertNil(gate.complete(generation: 10))
        XCTAssertTrue(gate.isInFlight)
        XCTAssertNil(gate.request(.details, generation: 11))
        XCTAssertEqual(gate.complete(generation: 11), .details)
    }

    func testProcessWideGenerationIsUniqueAcrossReplacementViews() {
        let first = VLCVideoPlayer.PlaybackSessionGeneration.make()
        let replacement = VLCVideoPlayer.PlaybackSessionGeneration.make()
        XCTAssertNotEqual(first, replacement)
        XCTAssertGreaterThan(replacement, first)
    }

    func testPlayingDetailsAreNotReadyUntilMatchingSnapshotArrives() {
        let configuration = VLCVideoPlayer.Configuration(url: URL(string: "https://example.com/live")!)
        var cache = VLCVideoPlayer.PlaybackInformationCache()
        cache.reset(configuration: configuration, generation: 3)
        XCTAssertFalse(cache.hasPlaybackDetails)

        XCTAssertFalse(cache.apply(makeInformation(configuration: configuration, generation: 2, audioIndex: 4), generation: 2))
        XCTAssertFalse(cache.hasPlaybackDetails)

        XCTAssertTrue(cache.apply(makeInformation(configuration: configuration, generation: 3, audioIndex: 4), generation: 3))
        XCTAssertTrue(cache.hasPlaybackDetails)
    }

    func testPlayingGateRequiresFreshEvidenceAfterBuffering() {
        var gate = VLCVideoPlayer.PlaybackPlayingGate()
        gate.reset(generation: 8)
        XCTAssertFalse(gate.observeTime(ticks: 1_000, generation: 8, isActuallyPlaying: true, detailsReady: true))
        XCTAssertTrue(gate.observeTime(ticks: 1_250, generation: 8, isActuallyPlaying: true, detailsReady: true))

        gate.noteNonPlaying(generation: 8)
        XCTAssertFalse(gate.observeTime(ticks: 1_250, generation: 8, isActuallyPlaying: true, detailsReady: true))
        XCTAssertTrue(gate.observeTime(ticks: 1_500, generation: 8, isActuallyPlaying: true, detailsReady: true))
    }

    func testPlayingGateCannotPublishFromPausedStateOrStaleGeneration() {
        var gate = VLCVideoPlayer.PlaybackPlayingGate()
        gate.reset(generation: 12)
        XCTAssertFalse(gate.observeTime(ticks: 200, generation: 12, isActuallyPlaying: false, detailsReady: true))
        XCTAssertFalse(gate.observeTime(ticks: 500, generation: 12, isActuallyPlaying: false, detailsReady: true))
        XCTAssertFalse(gate.observeTime(ticks: 800, generation: 11, isActuallyPlaying: true, detailsReady: true))
        XCTAssertFalse(gate.observeTime(ticks: 800, generation: 12, isActuallyPlaying: true, detailsReady: false))
    }

    func testEarlyEmptyDetailsCannotPublishBeforeLateDiscovery() {
        let configuration = VLCVideoPlayer.Configuration(url: URL(string: "https://example.com/live")!)
        var cache = VLCVideoPlayer.PlaybackInformationCache()
        var playing = VLCVideoPlayer.PlaybackPlayingGate()
        cache.reset(configuration: configuration, generation: 21)
        playing.reset(generation: 21)

        let empty = cache.information!
        XCTAssertFalse(cache.apply(empty, generation: 21))
        XCTAssertFalse(cache.hasPlaybackDetails)
        XCTAssertFalse(playing.observeTime(ticks: 100, generation: 21, isActuallyPlaying: true, detailsReady: cache.hasPlaybackDetails))
        XCTAssertFalse(playing.observeTime(ticks: 400, generation: 21, isActuallyPlaying: true, detailsReady: cache.hasPlaybackDetails))

        let discovered = makeInformation(
            configuration: configuration, generation: 21, audioIndex: 9, isSeekable: false
        )
        XCTAssertTrue(cache.apply(discovered, generation: 21, discoveryComplete: true))
        XCTAssertTrue(cache.hasPlaybackDetails)
        XCTAssertTrue(playing.observeTime(ticks: 700, generation: 21, isActuallyPlaying: true, detailsReady: cache.hasPlaybackDetails))

        let changed = makeInformation(
            configuration: configuration, generation: 21, audioIndex: 9, isSeekable: true
        )
        XCTAssertTrue(cache.apply(changed, generation: 21, discoveryComplete: true),
                      "Late seekability/track metadata must remain observable after playing")
    }

    private func makeInformation(
        configuration: VLCVideoPlayer.Configuration,
        generation: UInt64,
        audioIndex: Int,
        isSeekable: Bool = true
    ) -> VLCVideoPlayer.PlaybackInformation {
        let disabled = MediaTrack(index: -1, title: "Disable")
        let audio = MediaTrack(index: audioIndex, title: "Audio")
        return .init(
            sessionGeneration: generation,
            startConfiguration: configuration,
            position: 0.5,
            length: 1_000,
            isSeekable: isSeekable,
            playbackRate: 1,
            videoSize: CGSize(width: 1920, height: 1080),
            currentSubtitleTrack: disabled,
            currentAudioTrack: audio,
            currentVideoTrack: disabled,
            subtitleTracks: [disabled],
            audioTracks: [disabled, audio],
            videoTracks: [],
            statistics: .init()
        )
    }
}
