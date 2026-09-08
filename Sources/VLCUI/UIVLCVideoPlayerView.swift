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
    private var retirementInFlight = false
    private var retirementWaiters: [() -> Void] = []
    private var pendingReplacement: (
        generation: UInt64,
        configuration: VLCVideoPlayer.Configuration,
        completion: () -> Void
    )?
    private var replacementGeneration: UInt64 = 0
    private var globalHandoverWaitGeneration: UInt64?

    // Note: necessary as the configuration values have to be set
    //       after streams have been added and playback starts for
    //       at least one tick-changed report. This could cause a
    //       small, noticeable jump when playback starts.
    private var hasSetConfiguration: Bool = false
    private var lastAspectFill: Float = 0
    private var lastPlayerTicks: Int32 = 0
    private var lastPlayerState: VLCMediaPlayerState = .opening
    private var startupClock = VLCStartupClock()

    private var aspectFillScale: CGFloat {
        guard let currentMediaPlayer else { return 1 }
        let videoSize = currentMediaPlayer.videoSize
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
        if retirementInFlight {
            retirementWaiters.append(completion)
            return
        }
        guard let player = currentMediaPlayer else {
            completion()
            return
        }
        currentMediaPlayer = nil
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
        replacementGeneration &+= 1
        let generation = replacementGeneration
        pendingReplacement = (generation, newConfiguration, completion)

        guard !retirementInFlight else { return }
        guard let player = currentMediaPlayer else {
            installPendingReplacement()
            return
        }

        currentMediaPlayer = nil
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
        installVLCMediaPlayer(with: replacement.configuration)
        replacement.completion()
    }

    private func installVLCMediaPlayer(with newConfiguration: VLCVideoPlayer.Configuration) {

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

        if newConfiguration.startupDiagnosticsEnabled {
            VLCStartupDiagnostics.begin(player: newMediaPlayer, url: newConfiguration.url)
        }

        for child in newConfiguration.playbackChildren {
            newMediaPlayer.addPlaybackSlave(child.url, type: child.type.asVLCSlaveType, enforce: child.enforce)
        }

        hasSetConfiguration = false
        configuration = newConfiguration
        currentMediaPlayer = newMediaPlayer
        proxy?.mediaPlayer = newMediaPlayer
        lastPlayerTicks = 0
        lastPlayerState = .opening
        startupClock = VLCStartupClock()
        print("[VLCUI] startup player=\(ObjectIdentifier(newMediaPlayer)) initialVolume=\(newConfiguration.initialVolume.map(String.init) ?? "default")")

        if newConfiguration.autoPlay {
            newMediaPlayer.play()
        }
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

// MARK: constructPlaybackInformation

extension UIVLCVideoPlayerView {

    private func constructPlaybackInformation(player: VLCMediaPlayer, media: VLCMedia) -> VLCVideoPlayer.PlaybackInformation {

        let subtitleIndexes = player.videoSubTitlesIndexes as! [Int]
        let subtitleNames = player.videoSubTitlesNames as! [String]

        let audioIndexes = player.audioTrackIndexes as! [Int]
        let audioNames = player.audioTrackNames as! [String]

        let videoIndexes = player.videoTrackIndexes as! [Int]
        let videoNames = player.videoTrackNames as? [String]

        let subtitleTracks = zip(subtitleIndexes, subtitleNames).map { MediaTrack(index: $0, title: $1) }
        let audioTracks = zip(audioIndexes, audioNames).map { MediaTrack(index: $0, title: $1) }
        let videoTracks = zip(videoIndexes, videoNames ?? []).map { MediaTrack(index: $0, title: $1) }

        let currentSubtitleTrack: MediaTrack = subtitleTracks
            .first(where: { $0.index == player.currentVideoSubTitleIndex.asInt })
            .chaining(.init(index: -1, title: "Disable"))
        let currentAudioTrack: MediaTrack = audioTracks
            .first(where: { $0.index == player.currentAudioTrackIndex.asInt })
            .chaining(.init(index: -1, title: "Disable"))
        let currentVideoTrack: MediaTrack = videoTracks
            .first(where: { $0.index == player.currentVideoTrackIndex.asInt })
            .chaining(.init(index: -1, title: "Disable"))

        return VLCVideoPlayer.PlaybackInformation(
            startConfiguration: configuration,
            position: player.position,
            length: media.length.intValue.asInt,
            isSeekable: player.isSeekable,
            playbackRate: player.rate,
            videoSize: player.videoSize,
            currentSubtitleTrack: currentSubtitleTrack,
            currentAudioTrack: currentAudioTrack,
            currentVideoTrack: currentVideoTrack,
            subtitleTracks: subtitleTracks,
            audioTracks: audioTracks,
            videoTracks: videoTracks,
            statistics: .init(player: player, media: media)
        )
    }
}

// MARK: VLCMediaPlayerDelegate

extension UIVLCVideoPlayerView: VLCMediaPlayerDelegate {

    public func mediaPlayerTimeChanged(_ aNotification: Notification) {
        guard let player = aNotification.object as? VLCMediaPlayer,
              player === currentMediaPlayer,
              let media = player.media else { return }

        // A replaced VLCMediaPlayer can still have delegate events queued on the
        // main thread while its teardown runs in the background. Never let that old
        // instance mutate the shared state/configuration of the replacement player.
        let currentTicks = player.time.intValue
        let playbackInformation = constructPlaybackInformation(player: player, media: media)
        logStartupMilestones(player: player, info: playbackInformation)

        if !hasSetConfiguration {
            setConfigurationValues(
                with: player,
                from: configuration
            )

            hasSetConfiguration = true
        } else {
            onTicksUpdated(currentTicks.asInt, playbackInformation)
        }

        // Set playing state
        if lastPlayerState != .playing,
           abs(currentTicks - lastPlayerTicks) >= 200
        {
            onStateUpdated(.playing, playbackInformation)
            lastPlayerState = .playing
            lastPlayerTicks = currentTicks
        }

        // Replay
        if configuration.replay,
           lastPlayerState == .playing,
           abs(player.media!.length.intValue - currentTicks) <= 500
        {
            configuration.autoPlay = true
            configuration.startTime = .ticks(0)
            setupVLCMediaPlayer(with: configuration)
        }
    }

    public func mediaPlayerStateChanged(_ aNotification: Notification) {
        guard let player = aNotification.object as? VLCMediaPlayer,
              player === currentMediaPlayer,
              let media = player.media else { return }

        guard player.state != .playing, player.state != lastPlayerState else { return }

        let wrappedState = VLCVideoPlayer.State(rawValue: player.state.rawValue) ?? .error
        let playbackInformation = constructPlaybackInformation(player: player, media: media)
        logStartupMilestones(player: player, info: playbackInformation)

        onStateUpdated(wrappedState, playbackInformation)
        lastPlayerState = player.state
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
