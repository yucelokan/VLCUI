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
    private weak var proxy: VLCVideoPlayer.Proxy?
    private let onTicksUpdated: (Int, VLCVideoPlayer.PlaybackInformation) -> Void
    private let onStateUpdated: (VLCVideoPlayer.State, VLCVideoPlayer.PlaybackInformation) -> Void
    private let loggingInfo: (logger: VLCVideoPlayerLogger, level: VLCVideoPlayer.LoggingLevel)?
    private var currentMediaPlayer: VLCMediaPlayer?
    
    // Serial queue for thread-safe state management
    private let stateQueue = DispatchQueue(label: "com.vlcui.stateQueue", qos: .userInteractive)

    // PiP Support (VLCKit 4.0)
    #if os(iOS)
    private var pipWindowController: (any VLCPictureInPictureWindowControlling)?
    private var pipDrawable: VLCPiPDrawableView?
    public private(set) var isPiPActive: Bool = false
    public var isPiPPossible: Bool {
        return AVPictureInPictureController.isPictureInPictureSupported() && pipWindowController != nil
    }
    #endif

    private var hasSetConfiguration: Bool = false
    private var lastAspectFill: Float = 0
    private var lastPlayerTicks: Int32 = 0
    private var lastPlayerState: VLCMediaPlayerState = .opening
    
    // Flag to prevent callbacks during cleanup
    private var isCleaningUp: Bool = false
    
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
        guard videoSize.width > 0 && videoSize.height > 0 else { return 1 }
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
        cleanup()
    }
    
    /// Cleanup all resources - call before deallocation
    private func cleanup() {
        isCleaningUp = true
        
        // Remove delegate first to prevent any callbacks
        currentMediaPlayer?.delegate = nil
        
        // Stop playback
        currentMediaPlayer?.stop()
        
        // Clear PiP
        #if os(iOS)
        pipWindowController = nil
        pipDrawable = nil
        isPiPActive = false
        #endif
        
        // Clear references
        currentMediaPlayer = nil
        cachedPlaybackInfo = nil
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
        // CRITICAL: Set cleanup flag and remove delegate BEFORE stopping to prevent callbacks
        isCleaningUp = true
        currentMediaPlayer?.delegate = nil
        currentMediaPlayer?.stop()
        currentMediaPlayer = nil
        
        // Reset PiP state
        #if os(iOS)
        pipWindowController = nil
        pipDrawable = nil
        isPiPActive = false
        #endif

        // VLCKit 4.0: VLCMedia(url:) returns optional
        guard let media = VLCMedia(url: newConfiguration.url) else {
            print("[VLC] Failed to create media from URL: \(newConfiguration.url)")
            isCleaningUp = false
            return
        }
        media.addOptions(newConfiguration.options)

        // Create new media player
        let newMediaPlayer = VLCMediaPlayer()
        newMediaPlayer.media = media
        
        #if os(iOS)
        // VLCKit 4.0: Use VLCDrawable protocol for native PiP rendering
        let drawable = VLCPiPDrawableView(containerView: videoContentView, mediaController: self)
        drawable.onPictureInPictureReady = { [weak self] windowController in
            DispatchQueue.main.async {
                guard let self = self, !self.isCleaningUp else { return }
                self.pipWindowController = windowController
                print("[PiP] VLCKit PiP is ready!")
            }
        }
        self.pipDrawable = drawable
        newMediaPlayer.drawable = drawable
        #else
        newMediaPlayer.drawable = videoContentView
        #endif

        for child in newConfiguration.playbackChildren {
            newMediaPlayer.addPlaybackSlave(child.url, type: child.type.asVLCSlaveType, enforce: child.enforce)
        }

        configuration = newConfiguration
        currentMediaPlayer = newMediaPlayer
        proxy?.mediaPlayer = newMediaPlayer
        
        // Configure renderer manager with the new player
        proxy?.rendererManager.configure(with: newMediaPlayer)
        
        hasSetConfiguration = false
        lastPlayerTicks = 0
        lastPlayerState = .opening
        cachedPlaybackInfo = nil
        
        // Reset cleanup flag and set delegate AFTER everything is configured
        isCleaningUp = false
        newMediaPlayer.delegate = self

        if newConfiguration.autoPlay {
            newMediaPlayer.play()
        }
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
        guard let windowController = pipWindowController else { 
            print("[PiP] Cannot start - windowController is nil")
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
    
    // Fallback controller in case weak reference is nil
    private class FallbackMediaController: NSObject, VLCPictureInPictureMediaControlling {
        func play() {}
        func pause() {}
        func seek(by offset: Int64, completion: (() -> Void)!) { completion?() }
        func mediaLength() -> Int64 { 0 }
        func mediaTime() -> Int64 { 0 }
        func isMediaSeekable() -> Bool { false }
        func isMediaPlaying() -> Bool { false }
    }
    private let fallbackController = FallbackMediaController()
    
    public var onPictureInPictureReady: ((any VLCPictureInPictureWindowControlling) -> Void)?
    
    init(containerView: UIView, mediaController: any VLCPictureInPictureMediaControlling) {
        self.containerView = containerView
        self.mediaControllerRef = mediaController
        super.init()
    }
    
    // VLCDrawable protocol
    public func addSubview(_ view: UIView) {
        DispatchQueue.main.async { [weak self] in
            guard let containerView = self?.containerView else { return }
            containerView.addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
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
    
    // VLCPictureInPictureDrawable protocol - SAFE: Never returns nil
    public func mediaController() -> any VLCPictureInPictureMediaControlling {
        return mediaControllerRef ?? fallbackController
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
    
    /// Constructs lightweight playback info using ONLY cached data - SAFE for VLC callbacks
    /// IMPORTANT: Do NOT access any VLCMediaPlayer properties here - causes lock assertion failures
    private func constructLightweightPlaybackInformation(currentTicks: Int32, media: VLCMedia) -> VLCVideoPlayer.PlaybackInformation {
        // Use cached track info if available, otherwise create empty
        let cached = cachedPlaybackInfo
        let length = media.length.intValue.asInt
        
        // Calculate position from ticks and length (avoid player.position access)
        // For live streams, length is 0 or negative - position stays 0
        let position: Float = length > 0 ? Float(currentTicks) / Float(length) : 0
        
        // Default isSeekable to false for safety (live streams can't seek)
        // Will be updated when full track info is fetched
        return VLCVideoPlayer.PlaybackInformation(
            startConfiguration: configuration,
            position: position,
            length: length,
            isSeekable: cached?.isSeekable ?? false,
            playbackRate: cached?.playbackRate ?? 1.0,
            videoSize: cached?.videoSize ?? .zero,
            currentSubtitleTrack: cached?.currentSubtitleTrack ?? MediaTrack(index: -1, title: "Disable"),
            currentAudioTrack: cached?.currentAudioTrack ?? MediaTrack(index: -1, title: "Default"),
            subtitleTracks: cached?.subtitleTracks ?? [],
            audioTracks: cached?.audioTracks ?? []
        )
    }
    
    /// Schedules a track info update - call from time callback (does not block)
    private func scheduleTrackInfoUpdate(player: VLCMediaPlayer, media: VLCMedia) {
        // Skip if cleaning up
        guard !isCleaningUp else { return }
        
        let now = Date()
        guard now.timeIntervalSince(lastTrackUpdateTime) >= trackUpdateInterval else { return }
        lastTrackUpdateTime = now
        
        // Capture current player reference to verify in async block
        let capturedPlayer = player
        
        // Fetch track info on background queue - OUTSIDE of VLC callback context
        // Use asyncAfter(0) to escape callback without delay
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now()) { [weak self] in
            guard let self = self,
                  !self.isCleaningUp,
                  self.currentMediaPlayer === capturedPlayer else { return }
            
            self.fetchAndCacheTrackInfo(player: capturedPlayer, media: media)
        }
    }
    
    /// Fetches track info from player - call ONLY from background queue, NEVER from VLC callbacks
    private func fetchAndCacheTrackInfo(player: VLCMediaPlayer, media: VLCMedia) {
        // Safely access track information
        let textTracks = player.textTracks
        let audioTracksArray = player.audioTracks
        
        let subtitleTracks = textTracks.map { track in
            MediaTrack(index: Int(track.identifier), title: track.trackName)
        }
        
        let audioTracks = audioTracksArray.map { track in
            MediaTrack(index: Int(track.identifier), title: track.trackName)
        }
        
        let currentSubtitleTrack: MediaTrack = subtitleTracks
            .first(where: { $0.index == player.currentTextTrackIndex })
            ?? MediaTrack(index: -1, title: "Disable")
        
        let currentAudioTrack: MediaTrack = audioTracks
            .first(where: { $0.index == player.currentAudioTrackIdx })
            ?? MediaTrack(index: -1, title: "Disable")
        
        // These properties are safe to access from background
        let position = Float(player.position)
        let length = media.length.intValue.asInt
        let isSeekable = player.isSeekable
        let rate = player.rate
        let videoSize = player.videoSize
        
        let info = VLCVideoPlayer.PlaybackInformation(
            startConfiguration: self.configuration,
            position: position,
            length: length,
            isSeekable: isSeekable,
            playbackRate: rate,
            videoSize: videoSize,
            currentSubtitleTrack: currentSubtitleTrack,
            currentAudioTrack: currentAudioTrack,
            subtitleTracks: subtitleTracks,
            audioTracks: audioTracks
        )
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  !self.isCleaningUp,
                  self.currentMediaPlayer === player else { return }
            self.cachedPlaybackInfo = info
        }
    }
}

// MARK: VLCMediaPlayerDelegate

extension UIVLCVideoPlayerView: VLCMediaPlayerDelegate {

    public func mediaPlayerTimeChanged(_ aNotification: Notification) {
        // Skip if cleaning up
        guard !isCleaningUp else { return }
        
        // Throttle time updates
        let now = Date()
        guard now.timeIntervalSince(lastTimeUpdate) >= timeUpdateThrottle else { return }
        lastTimeUpdate = now
        
        // SAFETY: Verify the notification is from our current player
        guard let player = aNotification.object as? VLCMediaPlayer,
              player === currentMediaPlayer,
              let media = player.media else { return }
        
        // IMPORTANT: Only access player.time here - other properties can cause lock issues
        let currentTicks = player.time.intValue
        
        // Schedule track info update on background queue (not inside this callback)
        scheduleTrackInfoUpdate(player: player, media: media)
        
        // Use lightweight playback info - NO player property access inside
        let playbackInformation = constructLightweightPlaybackInformation(currentTicks: currentTicks, media: media)

        if !hasSetConfiguration {
            // Defer configuration to avoid lock issues
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.currentMediaPlayer === player else { return }
                self.setConfigurationValues(with: player, from: self.configuration)
                self.hasSetConfiguration = true
            }
        }
        
        // Always send ticks update for UI on main thread
        DispatchQueue.main.async { [weak self] in
            guard let self = self, 
                  !self.isCleaningUp,
                  self.currentMediaPlayer === player else { return }
            self.onTicksUpdated(currentTicks.asInt, playbackInformation)
        }
        
        // Invalidate PiP state when time changes
        #if os(iOS)
        DispatchQueue.main.async { [weak self] in
            self?.invalidatePiPPlaybackState()
        }
        #endif

        // Set playing state - do this synchronously to avoid race conditions
        if lastPlayerState != .playing,
           abs(currentTicks - lastPlayerTicks) >= 200
        {
            lastPlayerState = .playing
            lastPlayerTicks = currentTicks
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self,
                      !self.isCleaningUp,
                      self.currentMediaPlayer === player else { return }
                self.onStateUpdated(.playing, playbackInformation)
            }
        }

        // Replay
        if configuration.replay,
           lastPlayerState == .playing,
           abs(media.length.intValue - currentTicks) <= 500
        {
            var replayConfig = configuration
            replayConfig.autoPlay = true
            replayConfig.startTime = .ticks(0)
            setupVLCMediaPlayer(with: replayConfig)
        }
    }

    // VLCKit 4.0: New delegate signature
    public func mediaPlayerStateChanged(_ newState: VLCMediaPlayerState) {
        // Skip if cleaning up
        guard !isCleaningUp else { return }
        
        // SAFETY: Verify we still have a valid player
        guard let player = currentMediaPlayer, let media = player.media else { return }
        guard newState != lastPlayerState else { return }
        
        // Update state synchronously to avoid race conditions
        lastPlayerState = newState
        
        // Capture current player reference to verify in async block
        let capturedPlayer = player
        let wrappedState = VLCVideoPlayer.State(rawValue: newState.rawValue) ?? .error
        
        // Force update cached track info on state change
        lastTrackUpdateTime = .distantPast
        
        // Get current lightweight info using ONLY cached data - no VLC property access
        let currentTime = player.time.intValue
        let lightweightInfo = constructLightweightPlaybackInformation(currentTicks: currentTime, media: media)
        
        // Send state update immediately with cached info
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  !self.isCleaningUp,
                  self.currentMediaPlayer === capturedPlayer else { return }
            self.onStateUpdated(wrappedState, lightweightInfo)
        }
        
        // Schedule full track info update - run immediately but OUTSIDE VLC callback context
        // Use asyncAfter(0) to escape the callback context without adding delay
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now()) { [weak self] in
            guard let self = self,
                  !self.isCleaningUp,
                  self.currentMediaPlayer === capturedPlayer else { return }
            
            let playbackInformation = self.constructFullPlaybackInformation(player: player, media: media)
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self,
                      !self.isCleaningUp,
                      self.currentMediaPlayer === capturedPlayer else { return }
                self.cachedPlaybackInfo = playbackInformation
            }
        }
        
        // Invalidate PiP state when playback state changes
        #if os(iOS)
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.isCleaningUp else { return }
            self.invalidatePiPPlaybackState()
        }
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
