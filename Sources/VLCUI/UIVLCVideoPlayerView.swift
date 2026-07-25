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

    // Note: necessary as the configuration values have to be set
    //       after streams have been added and playback starts for
    //       at least one tick-changed report. This could cause a
    //       small, noticeable jump when playback starts.
    private var hasSetConfiguration: Bool = false
    private var lastAspectFill: Float = 0
    private var lastPlayerTicks: Int32 = 0
    private var lastPlayerState: VLCMediaPlayerState = .opening

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

        proxy?.videoPlayerView = self

        #if os(macOS)
        layer?.backgroundColor = .clear
        #else
        backgroundColor = .clear
        #endif

        setupVideoContentView()
        setupVLCMediaPlayer(with: configuration)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        releaseMediaPlayerOffMainThread(currentMediaPlayer)
    }

    /// Stops and releases a VLCMediaPlayer without blocking the calling thread.
    ///
    /// `-[VLCMediaPlayer dealloc]` synchronously calls `libvlc_media_player_destroy`,
    /// which does a blocking `pthread_join` waiting for libVLC's internal
    /// demux/decode/audio-output threads to fully terminate. On a stalled or slow
    /// network stream (the norm for IPTV-style playback) this join can take seconds,
    /// or in the worst case hang indefinitely if the internal thread is stuck (e.g. on
    /// a blocked network read). Since this view is normally torn down by SwiftUI on the
    /// main thread (when the hosting view is removed from the hierarchy), letting ARC
    /// release the last strong reference there freezes the UI, and in the worst case
    /// triggers a watchdog kill.
    ///
    /// This detaches the player from our drawable synchronously (cheap, avoids a stale
    /// player racing a new one for the same rendering surface), then hands the only
    /// strong reference to `VLCMediaPlayerTeardown.queue` — a single dedicated
    /// **serial** queue shared with `Proxy.stopAsync()`. `stop()` and the eventual
    /// release (and hence `dealloc` / `libvlc_media_player_destroy`) both happen there
    /// instead of on the caller's thread. Using the same serial queue as
    /// `Proxy.stopAsync()` (rather than each hopping onto the concurrent
    /// `DispatchQueue.global()` independently) guarantees a caller-initiated stop and
    /// this view's own teardown can never call into the same `VLCMediaPlayer`
    /// concurrently from two different threads.
    private func releaseMediaPlayerOffMainThread(_ player: VLCMediaPlayer?) {
        guard let player else { return }
        player.drawable = nil
        VLCMediaPlayerTeardown.queue.async {
            player.stop()
            // `player`'s last strong reference is released at the end of this closure,
            // on this background queue — not on the thread that called this function.
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

    func setupVLCMediaPlayer(with newConfiguration: VLCVideoPlayer.Configuration) {
        releaseMediaPlayerOffMainThread(currentMediaPlayer)
        currentMediaPlayer = nil

        let media = VLCMedia(url: newConfiguration.url)
        media.addOptions(newConfiguration.options)

        let newMediaPlayer = VLCMediaPlayer()
        newMediaPlayer.media = media
        newMediaPlayer.drawable = videoContentView
        newMediaPlayer.delegate = self

        if let loggingInfo {
            newMediaPlayer.libraryInstance.debugLogging = true
            newMediaPlayer.libraryInstance.debugLoggingLevel = loggingInfo.level.rawValue.asInt32
            newMediaPlayer.libraryInstance.debugLoggingTarget = self
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
            statistics: .init(stats: media.statistics)
        )
    }
}

// MARK: VLCMediaPlayerDelegate

extension UIVLCVideoPlayerView: VLCMediaPlayerDelegate {

    public func mediaPlayerTimeChanged(_ aNotification: Notification) {
        let player = aNotification.object as! VLCMediaPlayer
        let currentTicks = player.time.intValue
        let playbackInformation = constructPlaybackInformation(player: player, media: player.media!)

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
        let player = aNotification.object as! VLCMediaPlayer
        guard player.state != .playing, player.state != lastPlayerState else { return }

        let wrappedState = VLCVideoPlayer.State(rawValue: player.state.rawValue) ?? .error
        let playbackInformation = constructPlaybackInformation(player: player, media: player.media!)

        onStateUpdated(wrappedState, playbackInformation)
        lastPlayerState = player.state
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

        let defaultSubtitleTrackIndex = player.subtitleTrackIndex(from: configuration.subtitleIndex)
        player.currentVideoSubTitleIndex = defaultSubtitleTrackIndex.asInt32

        let defaultAudioTrackIndex = player.audioTrackIndex(from: configuration.audioIndex)
        player.currentAudioTrackIndex = defaultAudioTrackIndex.asInt32

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
