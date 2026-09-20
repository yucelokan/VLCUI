import Foundation
import VLCKitSPM

public extension VLCVideoPlayer {

    /// Process-wide identity for concrete VLC player sessions. SwiftUI can create
    /// a replacement view before dismantling its predecessor, so a per-view
    /// counter is not sufficient to reject late callbacks from the old player.
    enum PlaybackSessionGeneration {
        private static let lock = NSLock()
        private nonisolated(unsafe) static var nextValue: UInt64 = 0

        static func make() -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            nextValue &+= 1
            return nextValue
        }
    }

    struct PlaybackInformation {
        /// Identifies the concrete VLCMediaPlayer instance that produced this snapshot.
        /// A replacement, retry, or media switch always receives a new generation.
        public let sessionGeneration: UInt64
        public let startConfiguration: VLCVideoPlayer.Configuration
        public let position: Float
        public let length: Int
        public let isSeekable: Bool
        public let playbackRate: Float

        public let videoSize: CGSize

        public let currentSubtitleTrack: MediaTrack
        public let currentAudioTrack: MediaTrack
        public let currentVideoTrack: MediaTrack
        public let subtitleTracks: [MediaTrack]
        public let audioTracks: [MediaTrack]
        public let videoTracks: [MediaTrack]

        public let statistics: Statistics

        init(
            sessionGeneration: UInt64,
            startConfiguration: VLCVideoPlayer.Configuration,
            position: Float,
            length: Int,
            isSeekable: Bool,
            playbackRate: Float,
            videoSize: CGSize,
            currentSubtitleTrack: MediaTrack,
            currentAudioTrack: MediaTrack,
            currentVideoTrack: MediaTrack,
            subtitleTracks: [MediaTrack],
            audioTracks: [MediaTrack],
            videoTracks: [MediaTrack],
            statistics: Statistics
        ) {
            self.sessionGeneration = sessionGeneration
            self.startConfiguration = startConfiguration
            self.position = position
            self.length = length
            self.isSeekable = isSeekable
            self.playbackRate = playbackRate
            self.videoSize = videoSize
            self.currentSubtitleTrack = currentSubtitleTrack
            self.currentAudioTrack = currentAudioTrack
            self.currentVideoTrack = currentVideoTrack
            self.subtitleTracks = subtitleTracks
            self.audioTracks = audioTracks
            self.videoTracks = videoTracks
            self.statistics = statistics
        }

        func updatingTimeline(ticks: Int32) -> Self {
            let nextPosition = length > 0
                ? min(1, max(0, Float(ticks) / Float(length)))
                : position
            return .init(
                sessionGeneration: sessionGeneration,
                startConfiguration: startConfiguration,
                position: nextPosition,
                length: length,
                isSeekable: isSeekable,
                playbackRate: playbackRate,
                videoSize: videoSize,
                currentSubtitleTrack: currentSubtitleTrack,
                currentAudioTrack: currentAudioTrack,
                currentVideoTrack: currentVideoTrack,
                subtitleTracks: subtitleTracks,
                audioTracks: audioTracks,
                videoTracks: videoTracks,
                statistics: statistics
            )
        }

        func updatingStatistics(_ statistics: Statistics) -> Self {
            .init(
                sessionGeneration: sessionGeneration,
                startConfiguration: startConfiguration,
                position: position,
                length: length,
                isSeekable: isSeekable,
                playbackRate: playbackRate,
                videoSize: videoSize,
                currentSubtitleTrack: currentSubtitleTrack,
                currentAudioTrack: currentAudioTrack,
                currentVideoTrack: currentVideoTrack,
                subtitleTracks: subtitleTracks,
                audioTracks: audioTracks,
                videoTracks: videoTracks,
                statistics: statistics
            )
        }

        func updatingCapabilities(
            position: Float,
            length: Int,
            isSeekable: Bool,
            playbackRate: Float
        ) -> Self {
            .init(
                sessionGeneration: sessionGeneration,
                startConfiguration: startConfiguration,
                position: position,
                length: length,
                isSeekable: isSeekable,
                playbackRate: playbackRate,
                videoSize: videoSize,
                currentSubtitleTrack: currentSubtitleTrack,
                currentAudioTrack: currentAudioTrack,
                currentVideoTrack: currentVideoTrack,
                subtitleTracks: subtitleTracks,
                audioTracks: audioTracks,
                videoTracks: videoTracks,
                statistics: statistics
            )
        }
    }

    struct PlaybackInformationChanges: Equatable {
        let tracks: Bool
        let capabilities: Bool
        var any: Bool { tracks || capabilities }
    }

    /// Main-thread cache used by delegate callbacks. It never calls MobileVLCKit;
    /// expensive detail snapshots are applied only when their player generation matches.
    struct PlaybackInformationCache {
        private(set) var information: PlaybackInformation?
        private(set) var hasPlaybackDetails = false

        mutating func reset(configuration: Configuration, generation: UInt64) {
            let disabled = MediaTrack(index: -1, title: "Disable")
            information = .init(
                sessionGeneration: generation,
                startConfiguration: configuration,
                position: 0,
                length: 0,
                isSeekable: false,
                playbackRate: 1,
                videoSize: .zero,
                currentSubtitleTrack: disabled,
                currentAudioTrack: disabled,
                currentVideoTrack: disabled,
                subtitleTracks: [],
                audioTracks: [],
                videoTracks: [],
                statistics: .init()
            )
            hasPlaybackDetails = false
        }

        mutating func invalidate() {
            information = nil
            hasPlaybackDetails = false
        }

        mutating func snapshot(ticks: Int32) -> PlaybackInformation? {
            guard let current = information else { return nil }
            let updated = current.updatingTimeline(ticks: ticks)
            information = updated
            return updated
        }

        mutating func applyChanges(
            _ snapshot: PlaybackInformation,
            generation: UInt64,
            discoveryComplete: Bool = false
        ) -> PlaybackInformationChanges? {
            guard information?.sessionGeneration == generation,
                  snapshot.sessionGeneration == generation else { return nil }
            let previous = information
            information = snapshot
            // Empty snapshots captured before VLC's ES-added event are not
            // discovery evidence. A synthetic Disable-only list is teardown, not
            // a playable elementary stream. Explicit current-generation ES-added
            // remains valid for unusual audio-only/live inputs whose wrapper lists
            // are all empty even though VLC reported real stream discovery.
            let allTracks = snapshot.subtitleTracks + snapshot.audioTracks + snapshot.videoTracks
            let hasRealTrack = allTracks.contains { $0.index >= 0 }
            let hasOnlyEmptyLists = allTracks.isEmpty
            let hasPositiveVideoSize = snapshot.videoSize.width > 0 && snapshot.videoSize.height > 0
            hasPlaybackDetails = hasPlaybackDetails
                || hasRealTrack
                || hasPositiveVideoSize
                || (discoveryComplete && hasOnlyEmptyLists)
            let tracksChanged = previous?.subtitleTracks != snapshot.subtitleTracks
                || previous?.audioTracks != snapshot.audioTracks
                || previous?.videoTracks != snapshot.videoTracks
                || previous?.currentSubtitleTrack != snapshot.currentSubtitleTrack
                || previous?.currentAudioTrack != snapshot.currentAudioTrack
                || previous?.currentVideoTrack != snapshot.currentVideoTrack
            let capabilitiesChanged = previous?.length != snapshot.length
                || previous?.isSeekable != snapshot.isSeekable
                || previous?.playbackRate != snapshot.playbackRate
                || previous?.videoSize != snapshot.videoSize
            return .init(tracks: tracksChanged, capabilities: capabilitiesChanged)
        }

        @discardableResult
        mutating func apply(
            _ snapshot: PlaybackInformation,
            generation: UInt64,
            discoveryComplete: Bool = false
        ) -> Bool {
            applyChanges(
                snapshot,
                generation: generation,
                discoveryComplete: discoveryComplete
            )?.any == true
        }

        mutating func apply(_ statistics: Statistics, generation: UInt64) -> Bool {
            guard let current = information,
                  current.sessionGeneration == generation else { return false }
            information = current.updatingStatistics(statistics)
            return true
        }
    }

    enum PlaybackSnapshotKind: Int, Equatable {
        case statistics
        case capabilities
        case details
        case discoveredDetails
        case urgentStatistics
    }

    /// Alternates low-frequency health and capability reads so neither can
    /// starve the other while the single-active/single-pending gate stays bounded.
    struct PlaybackPeriodicRefreshScheduler {
        private var lastRequest: TimeInterval = 0
        private var nextKind: PlaybackSnapshotKind = .statistics

        mutating func reset() {
            lastRequest = 0
            nextKind = .statistics
        }

        mutating func request(
            now: TimeInterval,
            interval: TimeInterval
        ) -> PlaybackSnapshotKind? {
            guard now - lastRequest >= interval else { return nil }
            lastRequest = now
            let requested = nextKind
            nextKind = requested == .statistics ? .capabilities : .statistics
            return requested
        }
    }

    /// Coalesces refresh pressure to one active read plus at most one pending read.
    struct PlaybackSnapshotGate {
        private(set) var isInFlight = false
        private var inFlightGeneration: UInt64?
        private var pending: PlaybackSnapshotKind?

        mutating func request(_ kind: PlaybackSnapshotKind, generation: UInt64) -> PlaybackSnapshotKind? {
            guard !isInFlight else {
                guard inFlightGeneration == generation else { return nil }
                if pending == nil || kind.rawValue > pending!.rawValue { pending = kind }
                return nil
            }
            isInFlight = true
            inFlightGeneration = generation
            return kind
        }

        mutating func complete(generation: UInt64) -> PlaybackSnapshotKind? {
            guard inFlightGeneration == generation else { return nil }
            isInFlight = false
            inFlightGeneration = nil
            defer { pending = nil }
            return pending
        }

        mutating func invalidate() {
            isInFlight = false
            inFlightGeneration = nil
            pending = nil
        }
    }

    /// Requires evidence from the current VLC session and transition. A cached
    /// historical tick can never turn buffering/paused/stopped back into playing.
    struct PlaybackPlayingGate {
        private var generation: UInt64?
        private var epochBaselineTicks: Int32?
        private var previousTicks: Int32?
        private var hasPublished = false
        private let discontinuityThreshold: Int32 = 2_000

        mutating func reset(generation: UInt64) {
            self.generation = generation
            epochBaselineTicks = nil
            previousTicks = nil
            hasPublished = false
        }

        mutating func noteNonPlaying(generation: UInt64) {
            guard self.generation == generation else { return }
            epochBaselineTicks = nil
            previousTicks = nil
            hasPublished = false
        }

        mutating func noteSeek(generation: UInt64) {
            noteNonPlaying(generation: generation)
        }

        mutating func observeTime(
            ticks: Int32,
            generation: UInt64,
            isActuallyPlaying: Bool,
            detailsReady: Bool
        ) -> Bool {
            guard self.generation == generation else { return false }
            guard isActuallyPlaying, detailsReady else {
                epochBaselineTicks = nil
                previousTicks = nil
                hasPublished = false
                return false
            }
            guard !hasPublished else { return false }
            if let previousTicks, ticks < previousTicks {
                epochBaselineTicks = ticks
                self.previousTicks = ticks
                return false
            }
            previousTicks = ticks
            guard let baseline = epochBaselineTicks else {
                epochBaselineTicks = ticks
                return false
            }
            let progress = ticks - baseline
            if progress < 0 || progress > discontinuityThreshold {
                epochBaselineTicks = ticks
                return false
            }
            guard progress >= 200 else { return false }
            hasPublished = true
            return true
        }
    }

    struct Statistics {
        public let readBytes: Int
        public let inputBitrate: Float
        public let demuxReadBytes: Int
        public let demuxBitrate: Float
        public let demuxCorrupted: Int
        public let demuxDiscontinuity: Int
        public let decodedVideo: Int
        public let decodedAudio: Int
        public let displayedPictures: Int
        public let lostPictures: Int
        public let playedAudioBuffers: Int
        public let lostAudioBuffers: Int
        public let sentPackets: Int
        public let sentBytes: Int
        public let sendBitrate: Float

        /// A deterministic snapshot for media that has not created an input yet.
        /// libVLC reports statistics as unavailable in that state; exposing zeros
        /// prevents callers from mistaking uninitialised wrapper storage for real
        /// transport or decoder progress.
        public init() {
            readBytes = 0
            inputBitrate = 0
            demuxReadBytes = 0
            demuxBitrate = 0
            demuxCorrupted = 0
            demuxDiscontinuity = 0
            decodedVideo = 0
            decodedAudio = 0
            displayedPictures = 0
            lostPictures = 0
            playedAudioBuffers = 0
            lostAudioBuffers = 0
            sentPackets = 0
            sentBytes = 0
            sendBitrate = 0
        }

        public init(stats: VLCMedia.Stats) {
            readBytes = stats.readBytes.asInt
            inputBitrate = stats.inputBitrate
            demuxReadBytes = stats.demuxReadBytes.asInt
            demuxBitrate = stats.demuxBitrate
            demuxCorrupted = stats.demuxCorrupted.asInt
            demuxDiscontinuity = stats.demuxDiscontinuity.asInt
            decodedVideo = stats.decodedVideo.asInt
            decodedAudio = stats.decodedAudio.asInt
            displayedPictures = stats.displayedPictures.asInt
            lostPictures = stats.lostPictures.asInt
            playedAudioBuffers = stats.playedAudioBuffers.asInt
            lostAudioBuffers = stats.lostAudioBuffers.asInt
            sentPackets = stats.sentPackets.asInt
            sentBytes = stats.sentBytes.asInt
            sendBitrate = stats.sendBitrate
        }

        /// Normalises the Objective-C wrapper while libVLC has no input stats.
        /// Use this for every snapshot path; otherwise opening/state callbacks
        /// can publish the same indeterminate counters as direct proxy polling.
        init(player: VLCMediaPlayer, media: VLCMedia) {
            switch player.state {
            case .stopped, .opening, .ended, .error:
                self.init()
            default:
                self.init(stats: media.statistics)
            }
        }
    }
}
