import Combine

#if os(macOS)
import AppKit
#else
import UIKit
#endif

// VLCKit 4.0 uses unified VLCKit for all platforms
import VLCKit
#if os(iOS)
import AVKit
#endif

public class UIVLCVideoPlayerView: _PlatformView {

    private lazy var videoContentView = makeVideoContentView()
    
    private var configuration: VLCVideoPlayer.Configuration
    private var proxy: VLCVideoPlayer.Proxy?
    private let onTicksUpdated: (Int, VLCVideoPlayer.PlaybackInformation) -> Void
    private let onStateUpdated: (VLCVideoPlayer.State, VLCVideoPlayer.PlaybackInformation) -> Void
    private let loggingInfo: (logger: VLCVideoPlayerLogger, level: VLCVideoPlayer.LoggingLevel)?
    private var currentMediaPlayer: VLCMediaPlayer?

    // PiP Support (VLCKit 4.0)
    #if os(iOS)
    private var pipWindowController: (any VLCPictureInPictureWindowControlling)?
    public var isPiPActive: Bool = false
    public var isPiPPossible: Bool {
        return AVPictureInPictureController.isPictureInPictureSupported() && pipWindowController != nil
    }
    #endif

    private var hasSetConfiguration: Bool = false
    private var lastAspectFill: Float = 0
    private var lastPlayerTicks: Int32 = 0
    private var lastPlayerState: VLCMediaPlayerState = .opening
    
    // Throttling for time updates
    private var lastTimeUpdate: Date = .distantPast
    private let timeUpdateThrottle: TimeInterval = 0.1  // 100ms throttle
    
    // Cached playback information to avoid VLC lock issues
    private var cachedPlaybackInfo: VLCVideoPlayer.PlaybackInformation?
    private var lastTrackUpdateTime: Date = .distantPast
    private let trackUpdateInterval: TimeInterval = 1.0  // Update tracks every 1 second max

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
        currentMediaPlayer?.stop()
        currentMediaPlayer = nil

        // VLCKit 4.0: VLCMedia(url:) returns optional
        guard let media = VLCMedia(url: newConfiguration.url) else {
            print("[VLC] Failed to create media from URL: \(newConfiguration.url)")
            return
        }
        media.addOptions(newConfiguration.options)

        #if os(iOS)
        // VLCKit 4.0: Use VLCDrawable protocol for native rendering
        let drawable = VLCPiPDrawableView(containerView: videoContentView, mediaController: self)
        drawable.onPictureInPictureReady = { [weak self] windowController in
            self?.pipWindowController = windowController
            self?.proxy?.isPiPPossible = true
        }
        
        let mediaPlayer = VLCMediaPlayer(drawable: drawable)
        #else
        let mediaPlayer = VLCMediaPlayer(videoView: videoContentView as! VLCVideoView)
        #endif

        mediaPlayer.media = media
        mediaPlayer.delegate = self

        #if os(iOS)
        if let loggingInfo {
            switch loggingInfo.level {
            case .debug:
                mediaPlayer.debugLogging = true
                mediaPlayer.debugLoggingLevel = 3
            case .info:
                mediaPlayer.debugLogging = true
                mediaPlayer.debugLoggingLevel = 2
            default:
                mediaPlayer.debugLogging = false
            }
        }
        #endif

        configuration = newConfiguration
        currentMediaPlayer = mediaPlayer

        hasSetConfiguration = false
        lastPlayerState = .opening
        cachedPlaybackInfo = nil

        if configuration.autoPlay {
            mediaPlayer.play()
        }

        // PiP Setup (VLCKit 4.0)
        #if os(iOS)
        proxy?.isPiPActive = false
        #endif
    }

    func setAspectFill(with fill: Float) {
        lastAspectFill = fill

        if fill != 0 {
            videoContentView.scale(x: aspectFillScale, y: aspectFillScale)
        } else {
            videoContentView.apply(transform: .identity)
        }
    }
}

// MARK: - Picture in Picture (VLCKit 4.0)

#if os(iOS)
extension UIVLCVideoPlayerView {

    public func startPictureInPicture() {
        guard let windowController = pipWindowController else { return }
        windowController.startPictureInPicture()
        isPiPActive = true
        proxy?.isPiPActive = true
    }

    public func stopPictureInPicture() {
        guard let windowController = pipWindowController else { return }
        windowController.stopPictureInPicture()
        isPiPActive = false
        proxy?.isPiPActive = false
    }
    
    public func invalidatePiPPlaybackState() {
        pipWindowController?.invalidatePlaybackState()
    }
}
#endif

// MARK: - Private

private extension UIVLCVideoPlayerView {

    func makeVideoContentView() -> _PlatformView {
        let view = _PlatformView(frame: .zero)
        view.translatesAutoresizingMaskIntoConstraints = false

        #if os(macOS)
        view.layer?.backgroundColor = NSColor.black.cgColor
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

// MARK: - VLCPictureInPictureMediaControlling (VLCKit 4.0)

#if os(iOS)
extension UIVLCVideoPlayerView: VLCPictureInPictureMediaControlling {
    
    public func play() {
        currentMediaPlayer?.play()
    }
    
    public func pause() {
        currentMediaPlayer?.pause()
    }
    
    public func seek(by offset: Int64, completion: (() -> Void)!) {
        guard let player = currentMediaPlayer else { 
            completion?()
            return 
        }
        let currentTime = player.time.intValue
        let newTime = Int32(Int64(currentTime) + offset)
        player.time = VLCTime(int: newTime)
        completion?()
    }
    
    public func mediaLength() -> Int64 {
        return Int64(currentMediaPlayer?.media?.length.intValue ?? 0)
    }
    
    public func mediaTime() -> Int64 {
        return Int64(currentMediaPlayer?.time.intValue ?? 0)
    }
    
    public func isMediaSeekable() -> Bool {
        return currentMediaPlayer?.isSeekable ?? false
    }
    
    public func isMediaPlaying() -> Bool {
        return currentMediaPlayer?.isPlaying ?? false
    }
}
#endif

// MARK: - VLCPiPDrawableView (VLCKit 4.0 PiP Drawable)

#if os(iOS)
public class VLCPiPDrawableView: NSObject, VLCDrawable, VLCPictureInPictureDrawable {
    
    private weak var containerView: UIView?
    private weak var mediaControllerRef: (any VLCPictureInPictureMediaControlling)?
    
    public var onPictureInPictureReady: ((any VLCPictureInPictureWindowControlling) -> Void)?
    
    init(containerView: UIView, mediaController: any VLCPictureInPictureMediaControlling) {
        self.containerView = containerView
        self.mediaControllerRef = mediaController
        super.init()
    }
    
    // VLCDrawable protocol
    public func addSubview(_ view: UIView) {
        containerView?.addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        if let containerView = containerView {
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: containerView.topAnchor),
                view.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
                view.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: containerView.trailingAnchor)
            ])
        }
    }
    
    public func bounds() -> CGRect {
        return containerView?.bounds ?? .zero
    }
    
    // VLCPictureInPictureDrawable protocol
    public func mediaController() -> any VLCPictureInPictureMediaControlling {
        return mediaControllerRef!
    }
    
    public func pictureInPictureReady() -> ((any VLCPictureInPictureWindowControlling)?) -> Void {
        return { [weak self] windowController in
            if let windowController = windowController {
                self?.onPictureInPictureReady?(windowController)
            }
        }
    }
}
#endif

// MARK: - Playback Information Construction

extension UIVLCVideoPlayerView {

    /// Constructs playback info with track data - ONLY call from background when safe
    private func constructFullPlaybackInformation(player: VLCMediaPlayer, media: VLCMedia) -> VLCVideoPlayer.PlaybackInformation {
        // VLCKit 4.0: Use textTracks and audioTracks
        let subtitleTracks = player.textTracks.map { track in
            MediaTrack(index: Int(track.identifier), title: track.trackName)
        }
        
        let audioTracks = player.audioTracks.map { track in
            MediaTrack(index: Int(track.identifier), title: track.trackName)
        }
        
        // Get current selected tracks
        let currentSubtitleTrack: MediaTrack = subtitleTracks
            .first(where: { $0.index == player.currentTextTrackIndex })
            ?? MediaTrack(index: -1, title: "Disable")
        
        let currentAudioTrack: MediaTrack = audioTracks
            .first(where: { $0.index == player.currentAudioTrackIdx })
            ?? MediaTrack(index: -1, title: "Disable")

        return VLCVideoPlayer.PlaybackInformation(
            startConfiguration: configuration,
            position: Float(player.position),
            length: media.length.intValue.asInt,
            isSeekable: player.isSeekable,
            playbackRate: player.rate,
            videoSize: player.videoSize,
            currentSubtitleTrack: currentSubtitleTrack,
            currentAudioTrack: currentAudioTrack,
            subtitleTracks: subtitleTracks,
            audioTracks: audioTracks
        )
    }
    
    /// Constructs lightweight playback info using cached track data - safe for frequent calls
    private func constructLightweightPlaybackInformation(player: VLCMediaPlayer, media: VLCMedia) -> VLCVideoPlayer.PlaybackInformation {
        // Use cached track info if available, otherwise create empty
        let cached = cachedPlaybackInfo
        
        return VLCVideoPlayer.PlaybackInformation(
            startConfiguration: configuration,
            position: Float(player.position),
            length: media.length.intValue.asInt,
            isSeekable: player.isSeekable,
            playbackRate: player.rate,
            videoSize: player.videoSize,
            currentSubtitleTrack: cached?.currentSubtitleTrack ?? MediaTrack(index: -1, title: "Disable"),
            currentAudioTrack: cached?.currentAudioTrack ?? MediaTrack(index: -1, title: "Default"),
            subtitleTracks: cached?.subtitleTracks ?? [],
            audioTracks: cached?.audioTracks ?? []
        )
    }
    
    /// Updates cached track information - call periodically or on state change
    private func updateCachedTrackInfo(player: VLCMediaPlayer, media: VLCMedia) {
        let now = Date()
        guard now.timeIntervalSince(lastTrackUpdateTime) >= trackUpdateInterval else { return }
        lastTrackUpdateTime = now
        
        // Fetch track info on background queue to avoid blocking
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            let subtitleTracks = player.textTracks.map { track in
                MediaTrack(index: Int(track.identifier), title: track.trackName)
            }
            
            let audioTracks = player.audioTracks.map { track in
                MediaTrack(index: Int(track.identifier), title: track.trackName)
            }
            
            let currentSubtitleTrack: MediaTrack = subtitleTracks
                .first(where: { $0.index == player.currentTextTrackIndex })
                ?? MediaTrack(index: -1, title: "Disable")
            
            let currentAudioTrack: MediaTrack = audioTracks
                .first(where: { $0.index == player.currentAudioTrackIdx })
                ?? MediaTrack(index: -1, title: "Disable")
            
            let info = VLCVideoPlayer.PlaybackInformation(
                startConfiguration: self.configuration,
                position: Float(player.position),
                length: media.length.intValue.asInt,
                isSeekable: player.isSeekable,
                playbackRate: player.rate,
                videoSize: player.videoSize,
                currentSubtitleTrack: currentSubtitleTrack,
                currentAudioTrack: currentAudioTrack,
                subtitleTracks: subtitleTracks,
                audioTracks: audioTracks
            )
            
            DispatchQueue.main.async {
                self.cachedPlaybackInfo = info
            }
        }
    }
}

// MARK: VLCMediaPlayerDelegate

extension UIVLCVideoPlayerView: VLCMediaPlayerDelegate {

    public func mediaPlayerTimeChanged(_ aNotification: Notification) {
        // Throttle time updates
        let now = Date()
        guard now.timeIntervalSince(lastTimeUpdate) >= timeUpdateThrottle else { return }
        lastTimeUpdate = now
        
        guard let player = aNotification.object as? VLCMediaPlayer,
              let media = player.media else { return }
        
        let currentTicks = player.time.intValue
        
        // Update cached track info periodically (non-blocking)
        updateCachedTrackInfo(player: player, media: media)
        
        // Use lightweight playback info for time updates
        let playbackInformation = constructLightweightPlaybackInformation(player: player, media: media)

        if !hasSetConfiguration {
            setConfigurationValues(
                with: player,
                from: configuration
            )
            hasSetConfiguration = true
        }
        
        // Always send ticks update for UI
        DispatchQueue.main.async { [weak self] in
            self?.onTicksUpdated(currentTicks.asInt, playbackInformation)
        }
        
        // Invalidate PiP state when time changes
        #if os(iOS)
        invalidatePiPPlaybackState()
        #endif

        // Set playing state
        if lastPlayerState != .playing,
           abs(currentTicks - lastPlayerTicks) >= 200
        {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.onStateUpdated(.playing, playbackInformation)
            }
            lastPlayerState = .playing
            lastPlayerTicks = currentTicks
        }

        // Replay
        if configuration.replay,
           lastPlayerState == .playing,
           abs(media.length.intValue - currentTicks) <= 500
        {
            configuration.autoPlay = true
            configuration.startTime = .ticks(0)
            setupVLCMediaPlayer(with: configuration)
        }
    }

    // VLCKit 4.0: New delegate signature
    public func mediaPlayerStateChanged(_ newState: VLCMediaPlayerState) {
        guard let player = currentMediaPlayer, let media = player.media else { return }
        guard newState != lastPlayerState else { return }
        
        // Force update cached track info on state change
        lastTrackUpdateTime = .distantPast
        
        // For state changes, we need full track info - do it safely
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            let playbackInformation = self.constructFullPlaybackInformation(player: player, media: media)
            let wrappedState = VLCVideoPlayer.State(rawValue: newState.rawValue) ?? .error
            
            DispatchQueue.main.async {
                self.cachedPlaybackInfo = playbackInformation
                self.onStateUpdated(wrappedState, playbackInformation)
                self.lastPlayerState = newState
            }
        }
        
        // Invalidate PiP state when playback state changes
        #if os(iOS)
        invalidatePiPPlaybackState()
        #endif
    }

    private func setConfigurationValues(with player: VLCMediaPlayer, from configuration: VLCVideoPlayer.Configuration) {

        if configuration.startTime.asTicks != 0 {
            player.time = VLCTime(int: configuration.startTime.asTicks.asInt32)
        }

        let defaultPlayerSpeed = player.rate(from: configuration.rate)
        player.fastForward(atRate: defaultPlayerSpeed)

        if configuration.aspectFill {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.videoContentView.scale(x: self.aspectFillScale, y: self.aspectFillScale)
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.videoContentView.apply(transform: .identity)
            }
        }

        // VLCKit 4.0: Use new track selection API
        let defaultSubtitleTrackIndex = player.subtitleTrackIndex(from: configuration.subtitleIndex)
        player.selectTextTrack(at: defaultSubtitleTrackIndex)

        let defaultAudioTrackIndex = player.audioTrackIndex(from: configuration.audioIndex)
        player.selectAudioTrack(at: defaultAudioTrackIndex)

        player.setSubtitleSize(configuration.subtitleSize)
        player.setSubtitleFont(configuration.subtitleFont)
        player.setSubtitleColor(configuration.subtitleColor)
    }
}
