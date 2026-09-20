import Combine

#if os(macOS)
import AppKit
#else
import UIKit
#endif

import VLCKitSPM

public class UIVLCVideoPlayerView: _PlatformView {

    private lazy var videoContentView = makeVideoContentView()
    
    /// Returns the actual video rendering view (VLC's drawable)
    /// Use this for PiP frame capture instead of the parent view
    public var vlcDrawableView: _PlatformView {
        return videoContentView
    }

    private var configuration: VLCVideoPlayer.Configuration
    private var proxy: VLCVideoPlayer.Proxy?
    private let onTicksUpdated: (Int, VLCVideoPlayer.PlaybackInformation) -> Void
    private let onStateUpdated: (VLCVideoPlayer.State, VLCVideoPlayer.PlaybackInformation) -> Void
    private let loggingInfo: (logger: VLCVideoPlayerLogger, level: VLCVideoPlayer.LoggingLevel)?
    private var currentMediaPlayer: VLCMediaPlayer?
    private var currentMedia: VLCMedia?
    private var retirementInFlight = false
    private var retirementWaiters: [() -> Void] = []
    private var pendingReplacement: (
        generation: UInt64,
        configuration: VLCVideoPlayer.Configuration,
        completion: () -> Void
    )?
    private var replacementGeneration: UInt64 = 0
    private var globalHandoverWaitGeneration: UInt64?
    private var playbackInformationCache = VLCVideoPlayer.PlaybackInformationCache()
    private var playbackSnapshotGate = VLCVideoPlayer.PlaybackSnapshotGate()
    private var playbackPlayingGate = VLCVideoPlayer.PlaybackPlayingGate()
    private var periodicRefreshScheduler = VLCVideoPlayer.PlaybackPeriodicRefreshScheduler()

    private static let periodicRefreshInterval: TimeInterval = 0.5

    // Note: necessary as the configuration values have to be set
    //       after streams have been added and playback starts for
    //       at least one tick-changed report. This could cause a
    //       small, noticeable jump when playback starts.
    private var hasSetConfiguration: Bool = false
    private var lastAspectFill: Float = 0
    private var lastPlayerTicks: Int32 = 0
    private var lastPlayerState: VLCMediaPlayerState = .opening
    private var startupClock = VLCStartupClock()
    private var startupDiagnosticEpoch: Int?

    private var aspectFillScale: CGFloat {
        let videoSize = playbackInformationCache.information?.videoSize ?? .zero
        guard videoSize.width > 0, videoSize.height > 0 else { return 1 }
        let fillSize = CGSize.aspectFill(aspectRatio: videoSize, minimumSize: videoContentView.bounds.size)
        return fillSize.scale(other: videoContentView.bounds.size)
    }

    init(
        configuration: VLCVideoPlayer.Configuration,
        proxy: VLCVideoPlayer.Proxy?,
        onTicksUpdated: @escaping (Int, VLCVideoPlayer.PlaybackInformation) -> Void,
        onStateUpdated: @escaping (VLCVideoPlayer.State, VLCVideoPlayer.PlaybackInformation) -> Void,
        loggingInfo: (VLCVideoPlayerLogger, VLCVideoPlayer.LoggingLevel)?
    ) {
        self.configuration = configuration
        self.proxy = proxy
        self.onTicksUpdated = onTicksUpdated
        self.onStateUpdated = onStateUpdated
        self.loggingInfo = loggingInfo
        super.init(frame: .zero)

        // SwiftUI can install a new view before dismantling its predecessor.
        // Chain the first player to the predecessor's real retirement gate so
        // two views sharing one proxy never own provider inputs concurrently.
        let previousView = proxy?.videoPlayerView
        proxy?.videoPlayerView = self

        #if os(macOS)
        layer?.backgroundColor = .clear
        #else
        backgroundColor = .clear
        #endif

        setupVideoContentView()
        if let previousView, previousView !== self {
            previousView.retireCurrentMediaPlayer { [weak self] in
                self?.setupVLCMediaPlayer(with: configuration)
            }
        } else {
            setupVLCMediaPlayer(with: configuration)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        releaseMediaPlayerOffMainThread(currentMediaPlayer)
    }

    /// Silence and detach on the UI thread before background retirement.
    /// libVLC stop/dealloc can wait on network/decode threads. The per-player
    /// worker keeps that cost off UI and reports a stopped-or-released handover
    /// gate before a replacement is allowed to acquire the provider input.
    private func releaseMediaPlayerOffMainThread(
        _ player: VLCMediaPlayer?,
        completion: @escaping () -> Void = {}
    ) {
        guard let player else {
            completion()
            return
        }
        player.audio?.volume = 0
        // Stop producing delegate events before the replacement player is installed.
        // Events already queued by VLCKit are still rejected by the identity guards
        // in the delegate callbacks below.
        player.delegate = nil
        player.drawable = nil
        VLCMediaPlayerTeardown.retire(player, completion: completion)
    }

    /// A late dismantle must never clear the newer view's proxy binding.
    func retireCurrentMediaPlayer(completion: @escaping () -> Void = {}) {
        replacementGeneration &+= 1
        pendingReplacement = nil
        invalidatePlaybackInformationCache()
        if retirementInFlight {
            retirementWaiters.append(completion)
            return
        }
        guard let player = currentMediaPlayer else {
            completion()
            return
        }
        currentMediaPlayer = nil
        currentMedia = nil
        if proxy?.mediaPlayer === player { proxy?.mediaPlayer = nil }
        retirementInFlight = true
        releaseMediaPlayerOffMainThread(player) { [weak self] in
            guard let self else {
                completion()
                return
            }
            self.retirementInFlight = false
            completion()
            let waiters = self.retirementWaiters
            self.retirementWaiters.removeAll()
            waiters.forEach { $0() }
        }
    }

    private func setupVideoContentView() {
        addSubview(videoContentView)

        NSLayoutConstraint.activate([
            videoContentView.topAnchor.constraint(equalTo: topAnchor),
            videoContentView.bottomAnchor.constraint(equalTo: bottomAnchor),
            videoContentView.leftAnchor.constraint(equalTo: leftAnchor),
            videoContentView.rightAnchor.constraint(equalTo: rightAnchor),
        ])
    }

    func setupVLCMediaPlayer(
        with newConfiguration: VLCVideoPlayer.Configuration,
        completion: @escaping () -> Void = {}
    ) {
        let generation = VLCVideoPlayer.PlaybackSessionGeneration.make()
        replacementGeneration = generation
        pendingReplacement = (generation, newConfiguration, completion)

        guard !retirementInFlight else { return }
        guard let player = currentMediaPlayer else {
            installPendingReplacement()
            return
        }

        currentMediaPlayer = nil
        currentMedia = nil
        invalidatePlaybackInformationCache()
        if proxy?.mediaPlayer === player { proxy?.mediaPlayer = nil }
        retirementInFlight = true
        releaseMediaPlayerOffMainThread(player) { [weak self] in
            guard let self else { return }
            self.retirementInFlight = false
            self.installPendingReplacement()
            let waiters = self.retirementWaiters
            self.retirementWaiters.removeAll()
            waiters.forEach { $0() }
        }
    }

    private func installPendingReplacement(afterGlobalHandover: Bool = false) {
        guard !retirementInFlight, let replacement = pendingReplacement else { return }
        if replacement.configuration.serializesInputHandover, !afterGlobalHandover {
            guard globalHandoverWaitGeneration != replacement.generation else { return }
            globalHandoverWaitGeneration = replacement.generation
            VLCMediaPlayerTeardown.afterPendingRetirements { [weak self] in
                guard let self else { return }
                let waitedGeneration = self.globalHandoverWaitGeneration
                self.globalHandoverWaitGeneration = nil
                guard self.pendingReplacement?.generation == waitedGeneration else {
                    self.installPendingReplacement()
                    return
                }
                self.installPendingReplacement(afterGlobalHandover: true)
            }
            return
        }
        pendingReplacement = nil
        guard replacement.generation == replacementGeneration else { return }
        installVLCMediaPlayer(with: replacement.configuration, generation: replacement.generation)
        replacement.completion()
    }

    private func installVLCMediaPlayer(
        with newConfiguration: VLCVideoPlayer.Configuration,
        generation: UInt64
    ) {

        // Resolve only for a real player creation. Merely rebuilding a SwiftUI
        // configuration must not rotate or invalidate an active transport lease.
        let playbackURL = newConfiguration.mediaURLProvider?() ?? newConfiguration.url
        let media = VLCMedia(url: playbackURL)
        media.addOptions(newConfiguration.options)

        let newMediaPlayer = VLCMediaPlayer()
        // Never rely on a later buffering delegate event to silence startup.
        // That event can be delayed by UI work while libVLC is already decoding.
        if let volume = newConfiguration.initialVolume {
            newMediaPlayer.audio?.volume = min(200, max(0, volume))
        }
        newMediaPlayer.media = media
        newMediaPlayer.drawable = videoContentView
        newMediaPlayer.delegate = self

        if let loggingInfo {
            newMediaPlayer.libraryInstance.debugLogging = true
            newMediaPlayer.libraryInstance.debugLoggingLevel = loggingInfo.level.rawValue.asInt32
            newMediaPlayer.libraryInstance.debugLoggingTarget = self
        }

        if newConfiguration.startupDiagnosticsEnabled
            || newConfiguration.startupNetworkObservationEnabled {
            startupDiagnosticEpoch = VLCStartupDiagnostics.begin(
                player: newMediaPlayer,
                url: newConfiguration.url,
                emitsLogEvents: newConfiguration.startupDiagnosticsEnabled
            )
        } else {
            startupDiagnosticEpoch = nil
        }

        for child in newConfiguration.playbackChildren {
            newMediaPlayer.addPlaybackSlave(child.url, type: child.type.asVLCSlaveType, enforce: child.enforce)
        }

        hasSetConfiguration = false
        configuration = newConfiguration
        currentMediaPlayer = newMediaPlayer
        currentMedia = media
        proxy?.mediaPlayer = newMediaPlayer
        playbackInformationCache.reset(configuration: newConfiguration, generation: generation)
        playbackSnapshotGate.invalidate()
        playbackPlayingGate.reset(generation: generation)
        periodicRefreshScheduler.reset()
        lastPlayerTicks = 0
        lastPlayerState = .opening
        startupClock = VLCStartupClock()
        print("[VLCUI] startup player=\(ObjectIdentifier(newMediaPlayer)) initialVolume=\(newConfiguration.initialVolume.map(String.init) ?? "default")")

        if newConfiguration.autoPlay {
            newMediaPlayer.play()
        }
    }

    var startupNetworkActivitySnapshot: VLCStartupNetworkActivity? {
        guard let startupDiagnosticEpoch else { return nil }
        return VLCStartupDiagnostics.networkActivity(epoch: startupDiagnosticEpoch)
    }

    func setAspectFill(with percentage: Float) {
        guard percentage >= 0, percentage <= 1 else { return }
        let scale = 1 + CGFloat(percentage) * (aspectFillScale - 1)
        videoContentView.scale(x: scale, y: scale)

        lastAspectFill = percentage
    }

    private func makeVideoContentView() -> _PlatformView {
        let view = _PlatformView(frame: .zero)
        view.translatesAutoresizingMaskIntoConstraints = false

        #if os(macOS)
        view.layer?.backgroundColor = .black
        #else
        view.backgroundColor = .black
        #endif
        return view
    }

    #if !os(macOS)
    override public func layoutSubviews() {
        super.layoutSubviews()

        setAspectFill(with: lastAspectFill)
    }
    #endif
}

// MARK: Playback information cache

extension UIVLCVideoPlayerView {

    var currentSessionGeneration: UInt64? {
        guard currentMediaPlayer != nil else { return nil }
        return playbackInformationCache.information?.sessionGeneration
    }

    var cachedVideoSize: CGSize? {
        guard currentMediaPlayer != nil else { return nil }
        return playbackInformationCache.information?.videoSize
    }

    var cachedStatisticsSnapshot: VLCVideoPlayer.Statistics? {
        guard currentMediaPlayer != nil else { return nil }
        requestStatisticsRefresh()
        return playbackInformationCache.information?.statistics
    }

    func requestStatisticsRefresh() {
        requestPlaybackSnapshotRefresh(.urgentStatistics)
    }

    func requestPlaybackDetailsRefresh(discoveryComplete: Bool = false) {
        requestPlaybackSnapshotRefresh(discoveryComplete ? .discoveredDetails : .details)
    }

    private func invalidatePlaybackInformationCache() {
        playbackInformationCache.invalidate()
        playbackSnapshotGate.invalidate()
        periodicRefreshScheduler.reset()
    }

    private func cachedPlaybackInformation(ticks: Int32) -> VLCVideoPlayer.PlaybackInformation? {
        playbackInformationCache.snapshot(ticks: ticks)
    }

    private func requestPeriodicRefreshIfNeeded() {
        let now = ProcessInfo.processInfo.systemUptime
        guard let kind = periodicRefreshScheduler.request(
            now: now,
            interval: Self.periodicRefreshInterval
        ) else { return }
        requestPlaybackSnapshotRefresh(kind)
    }

    private func requestPlaybackSnapshotRefresh(_ requestedKind: VLCVideoPlayer.PlaybackSnapshotKind) {
        guard let player = currentMediaPlayer,
              let media = currentMedia,
              let generation = currentSessionGeneration,
              let kind = playbackSnapshotGate.request(requestedKind, generation: generation) else { return }
        performPlaybackSnapshotRefresh(
            kind,
            player: player,
            media: media,
            configuration: configuration,
            generation: generation,
            cachedStatistics: playbackInformationCache.information?.statistics ?? .init()
        )
    }

    private func performPlaybackSnapshotRefresh(
        _ kind: VLCVideoPlayer.PlaybackSnapshotKind,
        player: VLCMediaPlayer,
        media: VLCMedia,
        configuration: VLCVideoPlayer.Configuration,
        generation: UInt64,
        cachedStatistics: VLCVideoPlayer.Statistics
    ) {
        switch kind {
        case .details, .discoveredDetails:
            capturePlaybackDetails(
                stage: .subtitles,
                draft: .init(),
                player: player,
                media: media,
                configuration: configuration,
                generation: generation,
                statistics: cachedStatistics,
                discoveryComplete: kind == .discoveredDetails
            )
        case .statistics, .urgentStatistics:
            // Statistics are demand-driven by Proxy.statisticsSnapshot and are
            // never part of the playing/time callback critical path.
            DispatchQueue.main.async { [weak self, weak player, weak media] in
                guard let self, let player, let media,
                      self.isCurrent(player: player, generation: generation) else {
                    self?.finishPlaybackSnapshotRefresh(
                        details: nil, statistics: cachedStatistics,
                        player: player, generation: generation,
                        discoveryComplete: false
                    )
                    return
                }
                self.finishPlaybackSnapshotRefresh(
                    details: nil,
                    statistics: .init(player: player, media: media),
                    player: player,
                    generation: generation,
                    discoveryComplete: false
                )
            }
        case .capabilities:
            // One bounded timeline/capability group per second. This is separate
            // from track discovery, so late duration/seekability changes cannot
            // be lost when VLC emits no further ES-added event.
            DispatchQueue.main.async { [weak self, weak player, weak media] in
                guard let self, let player, let media,
                      self.isCurrent(player: player, generation: generation),
                      let cached = self.playbackInformationCache.information else {
                    self?.finishPlaybackSnapshotRefresh(
                        details: nil, statistics: cachedStatistics,
                        player: player, generation: generation,
                        discoveryComplete: false
                    )
                    return
                }
                let snapshot = cached.updatingCapabilities(
                    position: player.position,
                    length: media.length.intValue.asInt,
                    isSeekable: player.isSeekable,
                    playbackRate: player.rate
                )
                self.finishPlaybackSnapshotRefresh(
                    details: snapshot, statistics: cachedStatistics,
                    player: player, generation: generation,
                    discoveryComplete: false
                )
            }
        }
    }

    private enum PlaybackDetailStage { case subtitles, audio, video, timeline, videoSize }

    private struct PlaybackDetailsDraft {
        var subtitleTracks: [MediaTrack] = []
        var audioTracks: [MediaTrack] = []
        var videoTracks: [MediaTrack] = []
        var currentSubtitleTrack = MediaTrack(index: -1, title: "Disable")
        var currentAudioTrack = MediaTrack(index: -1, title: "Disable")
        var currentVideoTrack = MediaTrack(index: -1, title: "Disable")
        var position: Float = 0
        var length = 0
        var isSeekable = false
        var playbackRate: Float = 1
    }

    private func isCurrent(player: VLCMediaPlayer, generation: UInt64) -> Bool {
        player === currentMediaPlayer && generation == currentSessionGeneration
    }

    /// MobileVLCKit 3.7.2 marks these wrapper properties nonatomic on iOS.
    /// Keep every access on main, but read only one demand-specific group per
    /// run-loop turn. This bounds the work and removes the former full getter
    /// graph from state/time callbacks and from any single main-queue block.
    private func capturePlaybackDetails(
        stage: PlaybackDetailStage,
        draft: PlaybackDetailsDraft,
        player: VLCMediaPlayer,
        media: VLCMedia,
        configuration: VLCVideoPlayer.Configuration,
        generation: UInt64,
        statistics: VLCVideoPlayer.Statistics,
        discoveryComplete: Bool
    ) {
        DispatchQueue.main.async { [weak self, weak player, weak media] in
            guard let self, let player, let media,
                  self.isCurrent(player: player, generation: generation) else {
                self?.finishPlaybackSnapshotRefresh(
                    details: nil, statistics: statistics,
                    player: player, generation: generation,
                    discoveryComplete: false
                )
                return
            }
            var next = draft
            let nextStage: PlaybackDetailStage?
            switch stage {
            case .subtitles:
                let tracks = zip(
                    player.videoSubTitlesIndexes as? [Int] ?? [],
                    player.videoSubTitlesNames as? [String] ?? []
                ).map { MediaTrack(index: $0, title: $1) }
                next.subtitleTracks = tracks
                next.currentSubtitleTrack = tracks.first(where: {
                    $0.index == player.currentVideoSubTitleIndex.asInt
                }) ?? .init(index: -1, title: "Disable")
                nextStage = .audio
            case .audio:
                let tracks = zip(
                    player.audioTrackIndexes as? [Int] ?? [],
                    player.audioTrackNames as? [String] ?? []
                ).map { MediaTrack(index: $0, title: $1) }
                next.audioTracks = tracks
                next.currentAudioTrack = tracks.first(where: {
                    $0.index == player.currentAudioTrackIndex.asInt
                }) ?? .init(index: -1, title: "Disable")
                nextStage = .video
            case .video:
                let tracks = zip(
                    player.videoTrackIndexes as? [Int] ?? [],
                    player.videoTrackNames as? [String] ?? []
                ).map { MediaTrack(index: $0, title: $1) }
                next.videoTracks = tracks
                next.currentVideoTrack = tracks.first(where: {
                    $0.index == player.currentVideoTrackIndex.asInt
                }) ?? .init(index: -1, title: "Disable")
                nextStage = .timeline
            case .timeline:
                next.position = player.position
                next.length = media.length.intValue.asInt
                next.isSeekable = player.isSeekable
                next.playbackRate = player.rate
                nextStage = .videoSize
            case .videoSize:
                let snapshot = VLCVideoPlayer.PlaybackInformation(
                    sessionGeneration: generation,
                    startConfiguration: configuration,
                    position: next.position,
                    length: next.length,
                    isSeekable: next.isSeekable,
                    playbackRate: next.playbackRate,
                    videoSize: player.videoSize,
                    currentSubtitleTrack: next.currentSubtitleTrack,
                    currentAudioTrack: next.currentAudioTrack,
                    currentVideoTrack: next.currentVideoTrack,
                    subtitleTracks: next.subtitleTracks,
                    audioTracks: next.audioTracks,
                    videoTracks: next.videoTracks,
                    statistics: statistics
                )
                self.finishPlaybackSnapshotRefresh(
                    details: snapshot, statistics: statistics,
                    player: player, generation: generation,
                    discoveryComplete: discoveryComplete
                )
                nextStage = nil
            }
            if let nextStage {
                self.capturePlaybackDetails(
                    stage: nextStage,
                    draft: next,
                    player: player,
                    media: media,
                    configuration: configuration,
                    generation: generation,
                    statistics: statistics,
                    discoveryComplete: discoveryComplete
                )
            }
        }
    }

    private func finishPlaybackSnapshotRefresh(
        details: VLCVideoPlayer.PlaybackInformation?,
        statistics: VLCVideoPlayer.Statistics,
        player: VLCMediaPlayer?,
        generation: UInt64,
        discoveryComplete: Bool
    ) {
        let isCurrentSession = player != nil && player === currentMediaPlayer
            && generation == currentSessionGeneration
        var changes: VLCVideoPlayer.PlaybackInformationChanges?
        if isCurrentSession {
            if let details {
                changes = playbackInformationCache.applyChanges(
                    details,
                    generation: generation,
                    discoveryComplete: discoveryComplete
                )
            } else {
                _ = playbackInformationCache.apply(statistics, generation: generation)
            }
            if let info = playbackInformationCache.information {
                logStartupMilestones(player: player!, info: info)
                if changes?.capabilities == true {
                    onStateUpdated(.capabilitiesChanged, info)
                }
                if changes?.tracks == true {
                    onStateUpdated(.esAdded, info)
                }
                if details == nil {
                    onStateUpdated(.statisticsChanged, info)
                }
            }
        }

        if let pending = playbackSnapshotGate.complete(generation: generation) {
            requestPlaybackSnapshotRefresh(pending)
        }
    }

}

// MARK: VLCMediaPlayerDelegate

extension UIVLCVideoPlayerView: VLCMediaPlayerDelegate {

    public func mediaPlayerTimeChanged(_ aNotification: Notification) {
        guard let player = aNotification.object as? VLCMediaPlayer,
              player === currentMediaPlayer else { return }

        // A replaced VLCMediaPlayer can still have delegate events queued on the
        // main thread while its teardown runs in the background. Never let that old
        // instance mutate the shared state/configuration of the replacement player.
        let currentTicks = player.time.intValue
        guard let playbackInformation = cachedPlaybackInformation(ticks: currentTicks) else { return }
        requestPeriodicRefreshIfNeeded()
        if !hasSetConfiguration {
            setConfigurationValues(
                with: player,
                from: configuration
            )

            hasSetConfiguration = true
            requestPlaybackDetailsRefresh()
        } else {
            onTicksUpdated(currentTicks.asInt, playbackInformation)
        }

        // Set playing state
        let isActuallyPlaying = player.state == .playing
        if playbackPlayingGate.observeTime(
            ticks: currentTicks,
            generation: playbackInformation.sessionGeneration,
            isActuallyPlaying: isActuallyPlaying,
            detailsReady: playbackInformationCache.hasPlaybackDetails
        ) {
            onStateUpdated(.playing, playbackInformation)
            lastPlayerState = .playing
        } else if !playbackInformationCache.hasPlaybackDetails {
            requestPlaybackDetailsRefresh()
        }
        lastPlayerTicks = currentTicks

        // Replay
        if configuration.replay,
           lastPlayerState == .playing,
           playbackInformation.length > 0,
           abs(playbackInformation.length.asInt32 - currentTicks) <= 500
        {
            configuration.autoPlay = true
            configuration.startTime = .ticks(0)
            setupVLCMediaPlayer(with: configuration)
        }
    }

    func resetPlayingEvidenceForSeek() {
        guard let generation = currentSessionGeneration else { return }
        playbackPlayingGate.noteSeek(generation: generation)
    }

    public func mediaPlayerStateChanged(_ aNotification: Notification) {
        guard let player = aNotification.object as? VLCMediaPlayer,
              player === currentMediaPlayer else { return }

        let playerState = player.state
        guard playerState != .playing, playerState != lastPlayerState else { return }
        guard let playbackInformation = playbackInformationCache.information else { return }

        let wrappedState = VLCVideoPlayer.State(rawValue: playerState.rawValue) ?? .error
        if wrappedState == .esAdded {
            requestPlaybackDetailsRefresh(discoveryComplete: true)
        }

        playbackPlayingGate.noteNonPlaying(generation: playbackInformation.sessionGeneration)

        onStateUpdated(wrappedState, playbackInformation)
        lastPlayerState = playerState
    }

    private func logStartupMilestones(player: VLCMediaPlayer, info: VLCVideoPlayer.PlaybackInformation) {
        let stats = info.statistics
        let counters = [
            ("input_bytes", stats.readBytes),
            ("decoded_audio", stats.decodedAudio),
            ("decoded_video", stats.decodedVideo),
            ("displayed_picture_counter", stats.displayedPictures),
            ("played_audio_buffer_counter", stats.playedAudioBuffers)
        ]
        for (name, count) in counters {
            if let elapsed = startupClock.observe(name, count: count) {
                // These are first OBSERVED libVLC counters, not microphone/HDMI
                // measurements. Some SDKs never populate the output counters.
                print("[VLCUI] startup milestone=\(name) player=\(ObjectIdentifier(player)) observed_ms=\(elapsed) count=\(count) volume=\(player.audio?.volume ?? -1)")
            }
        }
    }

    private func setConfigurationValues(with player: VLCMediaPlayer, from configuration: VLCVideoPlayer.Configuration) {

        if configuration.startTime.asTicks != 0 {
            player.time = VLCTime(int: configuration.startTime.asTicks.asInt32)
        }

        let defaultPlayerSpeed = player.rate(from: configuration.rate)
        player.fastForward(atRate: defaultPlayerSpeed)

        if configuration.aspectFill {
            videoContentView.scale(x: aspectFillScale, y: aspectFillScale)
        } else {
            videoContentView.apply(transform: .identity)
        }

        // Only force a track when the caller explicitly requested one (.absolute).
        // `.auto` previously resolved to "first non-disable index", which silently
        // OVERRODE the track libVLC itself had already selected (e.g. via the
        // container's default-track flags) on the first time-changed callback —
        // after consumers had already observed and trusted the original selection.
        // `.auto` now means "leave libVLC's own selection untouched".
        if case .absolute = configuration.subtitleIndex {
            let defaultSubtitleTrackIndex = player.subtitleTrackIndex(from: configuration.subtitleIndex)
            player.currentVideoSubTitleIndex = defaultSubtitleTrackIndex.asInt32
        }

        if case .absolute = configuration.audioIndex {
            let defaultAudioTrackIndex = player.audioTrackIndex(from: configuration.audioIndex)
            player.currentAudioTrackIndex = defaultAudioTrackIndex.asInt32
        }

        player.setSubtitleSize(configuration.subtitleSize)
        player.setSubtitleFont(configuration.subtitleFont)
        player.setSubtitleColor(configuration.subtitleColor)
    }
}

// MARK: VLCLibraryLogReceiverProtocol

extension UIVLCVideoPlayerView: VLCLibraryLogReceiverProtocol {

    public func handleMessage(_ message: String, debugLevel level: Int32) {
        guard let loggingInfo, level >= loggingInfo.level.rawValue else { return }
        let level = VLCVideoPlayer.LoggingLevel(rawValue: level.asInt) ?? .info
        loggingInfo.logger.vlcVideoPlayer(didLog: message, at: level)
    }
}
