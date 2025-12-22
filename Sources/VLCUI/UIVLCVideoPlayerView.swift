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
    private var lastTimeUpdate: Date = .distantPast
    private let timeUpdateThrottle: TimeInterval = 0.05

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

        let newMediaPlayer = VLCMediaPlayer()
        newMediaPlayer.media = media
        
        // VLCKit 4.0 - Set drawable with PiP support
        #if os(iOS)
        let pipDrawable = VLCPiPDrawableView(
            containerView: videoContentView,
            mediaController: self
        )
        pipDrawable.onPictureInPictureReady = { [weak self] windowController in
            self?.pipWindowController = windowController
            print("[PiP] VLCKit PiP is ready!")
        }
        newMediaPlayer.drawable = pipDrawable
        #else
        newMediaPlayer.drawable = videoContentView
        #endif
        
        newMediaPlayer.delegate = self

        // VLCKit 4.0: Logging API changed - using console logger now
        // if let loggingInfo {
        //     Configure logging through VLCConsoleLogger if needed
        // }

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

    // MARK: - PiP Control Methods (VLCKit 4.0)
    
    #if os(iOS)
    public func startPictureInPicture() {
        guard let windowController = pipWindowController else {
            print("[PiP] PiP not available - windowController is nil")
            return
        }
        windowController.startPictureInPicture()
        isPiPActive = true
    }
    
    public func stopPictureInPicture() {
        guard let windowController = pipWindowController else { return }
        windowController.stopPictureInPicture()
        isPiPActive = false
    }
    
    public func invalidatePiPPlaybackState() {
        pipWindowController?.invalidatePlaybackState()
    }
    #endif

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

// MARK: constructPlaybackInformation

extension UIVLCVideoPlayerView {

    private func constructPlaybackInformation(player: VLCMediaPlayer, media: VLCMedia) -> VLCVideoPlayer.PlaybackInformation {

        // VLCKit 4.0: Use textTracks and audioTracks instead of videoSubTitlesIndexes/audioTrackIndexes
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
            position: Float(player.position),  // VLCKit 4.0: position is Double
            length: media.length.intValue.asInt,
            isSeekable: player.isSeekable,
            playbackRate: player.rate,
            videoSize: player.videoSize,
            currentSubtitleTrack: currentSubtitleTrack,
            currentAudioTrack: currentAudioTrack,
            subtitleTracks: subtitleTracks,
            audioTracks: audioTracks
            // VLCKit 4.0: Statistics are now in VLCMediaStats, using defaults
        )
    }
}

// MARK: VLCMediaPlayerDelegate

extension UIVLCVideoPlayerView: VLCMediaPlayerDelegate {

    public func mediaPlayerTimeChanged(_ aNotification: Notification) {
        // Throttle time updates to prevent dispatch_async crash
        let now = Date()
        guard now.timeIntervalSince(lastTimeUpdate) >= timeUpdateThrottle else { return }
        lastTimeUpdate = now
        
        guard let player = aNotification.object as? VLCMediaPlayer,
              let media = player.media else { return }
        
        let currentTicks = player.time.intValue
        let playbackInformation = constructPlaybackInformation(player: player, media: media)

        if !hasSetConfiguration {
            setConfigurationValues(
                with: player,
                from: configuration
            )

            hasSetConfiguration = true
        } else {
            onTicksUpdated(currentTicks.asInt, playbackInformation)
        }
        
        // Invalidate PiP state when time changes
        #if os(iOS)
        invalidatePiPPlaybackState()
        #endif

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
        guard newState != .playing, newState != lastPlayerState else { return }

        let wrappedState = VLCVideoPlayer.State(rawValue: newState.rawValue) ?? .error
        let playbackInformation = constructPlaybackInformation(player: player, media: media)

        onStateUpdated(wrappedState, playbackInformation)
        lastPlayerState = newState
        
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
            videoContentView.scale(x: aspectFillScale, y: aspectFillScale)
        } else {
            videoContentView.apply(transform: .identity)
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
