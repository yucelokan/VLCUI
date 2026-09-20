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

    func testPeriodicRefreshSchedulerAlternatesStatisticsAndCapabilities() {
        var scheduler = VLCVideoPlayer.PlaybackPeriodicRefreshScheduler()
        XCTAssertEqual(scheduler.request(now: 1, interval: 0.5), .statistics)
        XCTAssertNil(scheduler.request(now: 1.2, interval: 0.5))
        XCTAssertEqual(scheduler.request(now: 1.5, interval: 0.5), .capabilities)
        XCTAssertEqual(scheduler.request(now: 2, interval: 0.5), .statistics)
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

    func testPlayingGateAccumulatesSmallAndHalfSpeedTicks() {
        var gate = VLCVideoPlayer.PlaybackPlayingGate()
        gate.reset(generation: 30)
        for ticks in [1_000, 1_050, 1_100, 1_150] {
            XCTAssertFalse(gate.observeTime(
                ticks: Int32(ticks), generation: 30,
                isActuallyPlaying: true, detailsReady: true
            ))
        }
        XCTAssertTrue(gate.observeTime(
            ticks: 1_200, generation: 30,
            isActuallyPlaying: true, detailsReady: true
        ), "Sub-200ms callbacks must accumulate within the current playing epoch")
    }

    func testPlayingGateResetsForSeekDiscontinuity() {
        var gate = VLCVideoPlayer.PlaybackPlayingGate()
        gate.reset(generation: 31)
        XCTAssertFalse(gate.observeTime(ticks: 100, generation: 31, isActuallyPlaying: true, detailsReady: true))
        XCTAssertFalse(gate.observeTime(ticks: 20_000, generation: 31, isActuallyPlaying: true, detailsReady: true))
        XCTAssertFalse(gate.observeTime(ticks: 20_100, generation: 31, isActuallyPlaying: true, detailsReady: true))
        XCTAssertTrue(gate.observeTime(ticks: 20_200, generation: 31, isActuallyPlaying: true, detailsReady: true))
    }

    func testPlayingGateExplicitShortForwardSeekRequiresNewProgress() {
        var gate = VLCVideoPlayer.PlaybackPlayingGate()
        gate.reset(generation: 32)
        XCTAssertFalse(gate.observeTime(ticks: 1_000, generation: 32, isActuallyPlaying: true, detailsReady: true))
        XCTAssertFalse(gate.observeTime(ticks: 1_100, generation: 32, isActuallyPlaying: true, detailsReady: true))
        gate.noteSeek(generation: 32)
        XCTAssertFalse(gate.observeTime(ticks: 1_500, generation: 32, isActuallyPlaying: true, detailsReady: true))
        XCTAssertFalse(gate.observeTime(ticks: 1_600, generation: 32, isActuallyPlaying: true, detailsReady: true))
        XCTAssertTrue(gate.observeTime(ticks: 1_700, generation: 32, isActuallyPlaying: true, detailsReady: true))
    }

    func testPlayingGateBackwardJumpAboveOldBaselineStartsNewEpoch() {
        var gate = VLCVideoPlayer.PlaybackPlayingGate()
        gate.reset(generation: 33)
        XCTAssertFalse(gate.observeTime(ticks: 1_000, generation: 33, isActuallyPlaying: true, detailsReady: true))
        XCTAssertFalse(gate.observeTime(ticks: 1_100, generation: 33, isActuallyPlaying: true, detailsReady: true))
        XCTAssertFalse(gate.observeTime(ticks: 1_050, generation: 33, isActuallyPlaying: true, detailsReady: true))
        XCTAssertFalse(gate.observeTime(ticks: 1_150, generation: 33, isActuallyPlaying: true, detailsReady: true))
        XCTAssertTrue(gate.observeTime(ticks: 1_250, generation: 33, isActuallyPlaying: true, detailsReady: true))
    }

    @MainActor
    func testStatisticsRefreshPublishesCompletedSampleWithoutTimeCallback() async {
        let published = expectation(description: "Completed statistics sample published")
        let view = UIVLCVideoPlayerView(
            configuration: .init(
                url: URL(fileURLWithPath: "/nonexistent-statistics-fixture.mp4"),
                autoPlay: false
            ),
            proxy: nil,
            onTicksUpdated: { _, _ in },
            onStateUpdated: { state, _ in
                if state == .statisticsChanged { published.fulfill() }
            },
            loggingInfo: nil
        )
        view.requestStatisticsRefresh()
        await fulfillment(of: [published], timeout: 1)
        view.retireCurrentMediaPlayer()
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
        XCTAssertFalse(playing.observeTime(ticks: 700, generation: 21, isActuallyPlaying: true, detailsReady: cache.hasPlaybackDetails))
        XCTAssertTrue(playing.observeTime(ticks: 900, generation: 21, isActuallyPlaying: true, detailsReady: cache.hasPlaybackDetails))

        let changed = makeInformation(
            configuration: configuration, generation: 21, audioIndex: 9, isSeekable: true
        )
        XCTAssertTrue(cache.apply(changed, generation: 21, discoveryComplete: true),
                      "Late seekability/track metadata must remain observable after playing")
    }

    func testDisableOnlySnapshotIsNotDiscoveryReady() {
        let configuration = VLCVideoPlayer.Configuration(url: URL(string: "https://example.com/live")!)
        let disabled = MediaTrack(index: -1, title: "Disable")
        var cache = VLCVideoPlayer.PlaybackInformationCache()
        cache.reset(configuration: configuration, generation: 40)
        let disableOnly = VLCVideoPlayer.PlaybackInformation(
            sessionGeneration: 40,
            startConfiguration: configuration,
            position: 0,
            length: 0,
            isSeekable: false,
            playbackRate: 1,
            videoSize: .zero,
            currentSubtitleTrack: disabled,
            currentAudioTrack: disabled,
            currentVideoTrack: disabled,
            subtitleTracks: [disabled],
            audioTracks: [disabled],
            videoTracks: [],
            statistics: .init()
        )
        _ = cache.apply(disableOnly, generation: 40, discoveryComplete: true)
        XCTAssertFalse(cache.hasPlaybackDetails)
    }

    func testCapabilityChangesRemainIndependentFromTracks() {
        let configuration = VLCVideoPlayer.Configuration(url: URL(string: "https://example.com/vod")!)
        var cache = VLCVideoPlayer.PlaybackInformationCache()
        cache.reset(configuration: configuration, generation: 41)
        let unavailable = makeInformation(
            configuration: configuration, generation: 41,
            audioIndex: 4, isSeekable: false, length: 0
        )
        _ = cache.applyChanges(unavailable, generation: 41, discoveryComplete: true)
        let available = makeInformation(
            configuration: configuration, generation: 41,
            audioIndex: 4, isSeekable: true, length: 30_000
        )
        let becameAvailable = cache.applyChanges(available, generation: 41)
        XCTAssertEqual(becameAvailable, .init(tracks: false, capabilities: true))
        let becameUnavailable = cache.applyChanges(unavailable, generation: 41)
        XCTAssertEqual(becameUnavailable, .init(tracks: false, capabilities: true))
    }

    private func makeInformation(
        configuration: VLCVideoPlayer.Configuration,
        generation: UInt64,
        audioIndex: Int,
        isSeekable: Bool = true,
        length: Int = 1_000
    ) -> VLCVideoPlayer.PlaybackInformation {
        let disabled = MediaTrack(index: -1, title: "Disable")
        let audio = MediaTrack(index: audioIndex, title: "Audio")
        return .init(
            sessionGeneration: generation,
            startConfiguration: configuration,
            position: 0.5,
            length: length,
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
