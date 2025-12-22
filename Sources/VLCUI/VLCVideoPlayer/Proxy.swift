import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

// VLCKit 4.0 unified import
import VLCKit

public extension VLCVideoPlayer {

    class Proxy: ObservableObject {

        weak var mediaPlayer: VLCMediaPlayer?
        
        // MARK: - Renderer Discovery (Chromecast/AirPlay)
        public let rendererManager = RendererDiscoveryManager()
        
        // MARK: - Subtitle Transcoder
        public let subtitleTranscoder = SubtitleTranscoder()
        weak var videoPlayerView: UIVLCVideoPlayerView?

        @MainActor
        private var thumbnailHandlers = Set<ThumbnailHandler>()

        public init() {
            self.mediaPlayer = nil
            self.videoPlayerView = nil
        }

        // MARK: - Picture-in-Picture Support (VLCKit 4.0)
        
        #if os(iOS)
        public var isPiPPossible: Bool {
            return videoPlayerView?.isPiPPossible ?? false
        }
        
        public var isPiPActive: Bool {
            return videoPlayerView?.isPiPActive ?? false
        }
        
        public func startPictureInPicture() {
            videoPlayerView?.startPictureInPicture()
        }
        
        public func stopPictureInPicture() {
            videoPlayerView?.stopPictureInPicture()
        }
        
        public func togglePictureInPicture() {
            if isPiPActive {
                stopPictureInPicture()
            } else {
                startPictureInPicture()
            }
        }
        #endif

        // MARK: - Basic Playback Controls
        
        public func play() {
            mediaPlayer?.play()
        }

        public func pause() {
            mediaPlayer?.pause()
        }

        public func stop() {
            mediaPlayer?.stop()
        }

        @available(iOS, deprecated: 16.0, message: "Use `Duration` typed functions instead")
        @available(tvOS, deprecated: 16.0, message: "Use `Duration` typed functions instead")
        @available(macOS, deprecated: 13.0, message: "Use `Duration` typed functions instead")
        public func jumpForward(_ seconds: Int) {
            mediaPlayer?.jumpForward(Double(seconds))
        }

        @available(iOS, deprecated: 16.0, message: "Use `Duration` typed functions instead")
        @available(tvOS, deprecated: 16.0, message: "Use `Duration` typed functions instead")
        @available(macOS, deprecated: 13.0, message: "Use `Duration` typed functions instead")
        public func jumpBackward(_ seconds: Int) {
            mediaPlayer?.jumpBackward(Double(seconds))
        }

        @available(iOS 16.0, macOS 13.0, tvOS 16.0, *)
        public func jumpForward(_ seconds: Duration) {
            mediaPlayer?.jumpForward(Double(seconds.components.seconds))
        }

        @available(iOS 16.0, macOS 13.0, tvOS 16.0, *)
        public func jumpBackward(_ seconds: Duration) {
            mediaPlayer?.jumpBackward(Double(seconds.components.seconds))
        }

        public func gotoNextFrame() {
            mediaPlayer?.gotoNextFrame()
        }
        
        // MARK: - Track Selection

        public func setSubtitleTrack(_ index: ValueSelector<Int>) {
            guard let mediaPlayer else { return }
            let newTrackIndex = mediaPlayer.subtitleTrackIndex(from: index)
            mediaPlayer.selectTextTrack(at: newTrackIndex)
        }

        public func setAudioTrack(_ index: ValueSelector<Int>) {
            guard let mediaPlayer else { return }
            let newTrackIndex = mediaPlayer.audioTrackIndex(from: index)
            mediaPlayer.selectAudioTrack(at: newTrackIndex)
        }

        @available(iOS, deprecated: 16.0, message: "Use `Duration` typed functions instead")
        @available(tvOS, deprecated: 16.0, message: "Use `Duration` typed functions instead")
        @available(macOS, deprecated: 13.0, message: "Use `Duration` typed functions instead")
        public func setSubtitleDelay(_ interval: TimeSelector) {
            let delay = interval.asTicks * 1000
            mediaPlayer?.currentVideoSubTitleDelay = delay
        }

        @available(iOS, deprecated: 16.0, message: "Use `Duration` typed functions instead")
        @available(tvOS, deprecated: 16.0, message: "Use `Duration` typed functions instead")
        @available(macOS, deprecated: 13.0, message: "Use `Duration` typed functions instead")
        public func setAudioDelay(_ interval: TimeSelector) {
            let delay = interval.asTicks * 1000
            mediaPlayer?.currentAudioPlaybackDelay = delay
        }

        public func setRate(_ rate: ValueSelector<Float>) {
            guard let mediaPlayer else { return }
            let newRate = mediaPlayer.rate(from: rate)
            mediaPlayer.fastForward(atRate: newRate)
        }

        @available(iOS, deprecated: 16.0, message: "Use `Duration` typed functions instead")
        @available(tvOS, deprecated: 16.0, message: "Use `Duration` typed functions instead")
        @available(macOS, deprecated: 13.0, message: "Use `Duration` typed functions instead")
        public func setTime(_ time: TimeSelector) {
            guard let mediaPlayer,
                  let media = mediaPlayer.media else { return }

            guard time.asTicks >= 0 && time.asTicks <= media.length.intValue else { return }
            mediaPlayer.time = VLCTime(int: time.asTicks.asInt32)
        }

        @available(iOS 16.0, macOS 13.0, tvOS 16.0, *)
        public func setSubtitleDelay(_ seconds: Duration) {
            mediaPlayer?.currentVideoSubTitleDelay = Int(seconds.microseconds)
        }

        @available(iOS 16.0, macOS 13.0, tvOS 16.0, *)
        public func setAudioDelay(_ seconds: Duration) {
            mediaPlayer?.currentAudioPlaybackDelay = Int(seconds.microseconds)
        }

        @available(iOS 16.0, macOS 13.0, tvOS 16.0, *)
        public func setSeconds(_ seconds: Duration) {
            guard let mediaPlayer,
                  let media = mediaPlayer.media else { return }

            guard seconds <= media.duration else { return }

            mediaPlayer.time = VLCTime(int: Int32(seconds.milliseconds))
        }

        #if !os(macOS)
        public func aspectFill(_ percentage: Float) {
            videoPlayerView?.setAspectFill(with: percentage)
        }

        public func setSubtitleSize(_ size: ValueSelector<Int>) {
            mediaPlayer?.setSubtitleSize(size)
        }

        public func setSubtitleFont(_ font: ValueSelector<_PlatformFont>) {
            mediaPlayer?.setSubtitleFont(font)
        }

        public func setSubtitleFont(_ fontName: String) {
            mediaPlayer?.setSubtitleFont(fontName)
        }

        public func setSubtitleColor(_ color: ValueSelector<_PlatformColor>) {
            mediaPlayer?.setSubtitleColor(color)
        }
        #endif

        public func addPlaybackChild(_ child: PlaybackChild) {
            mediaPlayer?.addPlaybackSlave(child.url, type: child.type.asVLCSlaveType, enforce: child.enforce)
        }

        public func playNewMedia(_ newConfiguration: Configuration) {
            videoPlayerView?.setupVLCMediaPlayer(with: newConfiguration)
        }

        public func saveSnapshot(atPath path: String) {
            guard let mediaPlayer else { return }

            let videoSize = mediaPlayer.videoSize

            mediaPlayer.saveVideoSnapshot(
                at: path,
                withWidth: Int32(videoSize.width),
                andHeight: Int32(videoSize.height)
            )
        }

        public func startRecording(atPath path: String) {
            mediaPlayer?.startRecording(atPath: path)
        }

        public func stopRecording() {
            mediaPlayer?.stopRecording()
        }

        @MainActor
        public func fetchThumbnail(position: Float, size: CGSize) async throws(ThumbnailError) -> _PlatformImage {
            guard let media = mediaPlayer?.media else {
                throw ThumbnailError.noMedia
            }

            return try await withCheckedContinuation { continuation in

                let handler = ThumbnailHandler(
                    continuation: continuation
                ) { [weak self] handler in
                    self?.thumbnailHandlers.remove(handler)
                }

                let thumbnailer = VLCMediaThumbnailer(
                    media: media,
                    andDelegate: handler
                )

                self.thumbnailHandlers.insert(handler)

                thumbnailer.snapshotPosition = position
                thumbnailer.thumbnailWidth = size.width
                thumbnailer.thumbnailHeight = size.height

                thumbnailer.fetchThumbnail()
            }.get()
        }

        public func setAspectRatio(_ ratio: VLCVideoPlayer.AspectRatio) {
            guard ratio != .default else {
                mediaPlayer?.videoAspectRatio = nil
                return
            }
            // VLCKit 4.0: videoAspectRatio is now String? instead of char*
            mediaPlayer?.videoAspectRatio = ratio.rawValue
        }
        
        // MARK: - VLCKit 4.0 New Features
        
        // MARK: Video Adjust Filter (Brightness, Contrast, etc.)
        
        /// Enable or disable video adjust filter
        public var isAdjustFilterEnabled: Bool {
            get { mediaPlayer?.adjustFilter.isEnabled ?? false }
            set { mediaPlayer?.adjustFilter.isEnabled = newValue }
        }
        
        /// Set video contrast (range: 0.0 - 2.0, default: 1.0)
        public func setContrast(_ value: Float) {
            mediaPlayer?.adjustFilter.contrast.value = value
        }
        
        /// Get current contrast value
        public var contrast: Float {
            (mediaPlayer?.adjustFilter.contrast.value as? Float) ?? 1.0
        }
        
        /// Set video brightness (range: 0.0 - 2.0, default: 1.0)
        public func setBrightness(_ value: Float) {
            mediaPlayer?.adjustFilter.brightness.value = value
        }
        
        /// Get current brightness value
        public var brightness: Float {
            (mediaPlayer?.adjustFilter.brightness.value as? Float) ?? 1.0
        }
        
        /// Set video saturation (range: 0.0 - 3.0, default: 1.0)
        public func setSaturation(_ value: Float) {
            mediaPlayer?.adjustFilter.saturation.value = value
        }
        
        /// Get current saturation value
        public var saturation: Float {
            (mediaPlayer?.adjustFilter.saturation.value as? Float) ?? 1.0
        }
        
        /// Set video hue (range: -180 - 180, default: 0)
        public func setHue(_ value: Float) {
            mediaPlayer?.adjustFilter.hue.value = value
        }
        
        /// Get current hue value
        public var hue: Float {
            (mediaPlayer?.adjustFilter.hue.value as? Float) ?? 0.0
        }
        
        /// Set video gamma (range: 0.0 - 10.0, default: 1.0)
        public func setGamma(_ value: Float) {
            mediaPlayer?.adjustFilter.gamma.value = value
        }
        
        /// Get current gamma value
        public var gamma: Float {
            (mediaPlayer?.adjustFilter.gamma.value as? Float) ?? 1.0
        }
        
        /// Reset all video adjustments to defaults
        public func resetVideoAdjustments() {
            setContrast(1.0)
            setBrightness(1.0)
            setSaturation(1.0)
            setHue(0.0)
            setGamma(1.0)
        }
        
        // MARK: Audio Equalizer
        
        /// Set audio equalizer with a preset
        public func setEqualizerPreset(_ presetIndex: Int) {
            let presets = VLCAudioEqualizer.presets
            guard presetIndex >= 0 && presetIndex < presets.count else { return }
            let preset = presets[presetIndex]
            mediaPlayer?.equalizer = VLCAudioEqualizer(preset: preset)
        }
        
        /// Get available equalizer preset names
        public var equalizerPresetNames: [String] {
            VLCAudioEqualizer.presets.map { $0.name }
        }
        
        /// Disable equalizer
        public func disableEqualizer() {
            mediaPlayer?.equalizer = nil
        }
        
        /// Set equalizer preamp value (-20.0 to 20.0)
        public func setEqualizerPreamp(_ value: Float) {
            mediaPlayer?.equalizer?.preAmplification = value
        }
        
        /// Set equalizer band amplification
        /// - Parameters:
        ///   - bandIndex: Index of the band (0-9 typically)
        ///   - value: Amplification value (-20.0 to 20.0)
        public func setEqualizerBand(at bandIndex: Int, value: Float) {
            guard let bands = mediaPlayer?.equalizer?.bands,
                  bandIndex >= 0 && bandIndex < bands.count else { return }
            bands[bandIndex].amplification = value
        }
        
        // MARK: Audio Stereo Mode
        
        /// Audio stereo mode options
        public enum StereoMode: UInt {
            case unset = 0
            case stereo = 1
            case reverseStereo = 2
            case left = 3
            case right = 4
            case dolby = 5
            case mono = 7
        }
        
        /// Set audio stereo mode
        public func setAudioStereoMode(_ mode: StereoMode) {
            mediaPlayer?.audioStereoMode = VLCMediaPlayer.AudioStereoMode(rawValue: mode.rawValue) ?? .unset
        }
        
        /// Get current audio stereo mode
        public var audioStereoMode: StereoMode {
            StereoMode(rawValue: mediaPlayer?.audioStereoMode.rawValue ?? 0) ?? .unset
        }
        
        // MARK: Audio Mix Mode (Surround)
        
        /// Audio mix mode options (surround configurations)
        public enum AudioMixMode: UInt {
            case unset = 0
            case stereo = 1
            case binaural = 2   // For headphones - 3D audio effect
            case surround4_0 = 3
            case surround5_1 = 4
            case surround7_1 = 5
        }
        
        /// Set audio mix mode (for surround sound)
        public func setAudioMixMode(_ mode: AudioMixMode) {
            mediaPlayer?.audioMixMode = VLCMediaPlayer.AudioMixMode(rawValue: UInt32(mode.rawValue)) ?? .modeUnset
        }
        
        /// Get current audio mix mode
        public var audioMixMode: AudioMixMode {
            AudioMixMode(rawValue: UInt(mediaPlayer?.audioMixMode.rawValue ?? 0)) ?? .unset
        }
        
        // MARK: 360° Video Support (VR)
        
        /// Check if current media is 360° video
        public var is360Video: Bool {
            // If we can set viewpoint, it's likely 360° content
            return mediaPlayer?.yaw != nil
        }
        
        /// Set 360° video viewpoint
        /// - Parameters:
        ///   - yaw: Horizontal rotation (-180 to 180)
        ///   - pitch: Vertical rotation (-90 to 90)
        ///   - roll: Roll rotation (-180 to 180)
        ///   - fov: Field of view (0 to 180, default 80)
        public func set360Viewpoint(yaw: Float, pitch: Float, roll: Float = 0, fov: Float = 80) {
            mediaPlayer?.updateViewpoint(yaw, pitch: pitch, roll: roll, fov: fov, absolute: true)
        }
        
        /// Update 360° viewpoint relatively (for gesture control)
        public func update360Viewpoint(deltaYaw: Float, deltaPitch: Float) {
            mediaPlayer?.updateViewpoint(deltaYaw, pitch: deltaPitch, roll: 0, fov: 80, absolute: false)
        }
        
        /// Reset 360° viewpoint to center
        public func reset360Viewpoint() {
            set360Viewpoint(yaw: 0, pitch: 0, roll: 0, fov: 80)
        }
        
        // MARK: Chapter & Title Navigation
        
        /// Current chapter index (-1 if no chapters)
        public var currentChapter: Int {
            get { Int(mediaPlayer?.currentChapterIndex ?? -1) }
            set { mediaPlayer?.currentChapterIndex = Int32(newValue) }
        }
        
        /// Go to next chapter
        public func nextChapter() {
            mediaPlayer?.nextChapter()
        }
        
        /// Go to previous chapter
        public func previousChapter() {
            mediaPlayer?.previousChapter()
        }
        
        /// Number of chapters for current title
        public var numberOfChapters: Int {
            guard let player = mediaPlayer else { return 0 }
            return Int(player.numberOfChapters(forTitle: player.currentTitleIndex))
        }
        
        /// Current title index
        public var currentTitle: Int {
            get { Int(mediaPlayer?.currentTitleIndex ?? -1) }
            set { mediaPlayer?.currentTitleIndex = Int32(newValue) }
        }
        
        /// Number of titles
        public var numberOfTitles: Int {
            Int(mediaPlayer?.numberOfTitles ?? 0)
        }
        
        // MARK: Deinterlace
        
        /// Available deinterlace modes
        public enum DeinterlaceMode: String {
            case disabled = ""
            case discard = "discard"
            case blend = "blend"
            case mean = "mean"
            case bob = "bob"
            case linear = "linear"
            case x = "x"
            case yadif = "yadif"
            case yadif2x = "yadif2x"
            case phosphor = "phosphor"
            case ivtc = "ivtc"
        }
        
        /// Set deinterlace mode
        public func setDeinterlace(_ mode: DeinterlaceMode) {
            if mode == .disabled {
                mediaPlayer?.setDeinterlaceFilter(nil)
            } else {
                mediaPlayer?.setDeinterlaceFilter(mode.rawValue)
            }
        }
        
        // MARK: Media Metadata
        
        /// Get media metadata
        public var metadata: MediaMetadata? {
            guard let media = mediaPlayer?.media else { return nil }
            let meta = media.metaData
            return MediaMetadata(
                title: meta.title,
                artist: meta.artist,
                album: meta.album,
                genre: meta.genre,
                trackNumber: Int(meta.trackNumber),
                artwork: meta.artwork,
                date: meta.date,
                nowPlaying: meta.nowPlaying,
                director: meta.director,
                season: Int(meta.season),
                episode: Int(meta.episode),
                showName: meta.showName
            )
        }
        
        // MARK: Video Scale
        
        /// Set video scale factor (0 = auto fit to window)
        public func setVideoScale(_ scale: Float) {
            mediaPlayer?.scaleFactor = scale
        }
        
        /// Get current video scale factor
        public var videoScale: Float {
            mediaPlayer?.scaleFactor ?? 0
        }
        
        // MARK: Crop
        
        /// Set video crop ratio
        public func setCropRatio(numerator: UInt32, denominator: UInt32) {
            mediaPlayer?.setCropRatioWithNumerator(numerator, denominator: denominator)
        }
        
        /// Clear crop (show full video)
        public func clearCrop() {
            mediaPlayer?.setCropRatioWithNumerator(0, denominator: 0)
        }
    }
    
    // MARK: - Media Metadata Structure
    
    struct MediaMetadata {
        public let title: String?
        public let artist: String?
        public let album: String?
        public let genre: String?
        public let trackNumber: Int
        public let artwork: _PlatformImage?
        public let date: String?
        public let nowPlaying: String?
        public let director: String?
        public let season: Int
        public let episode: Int
        public let showName: String?
        
        /// Formatted episode string (e.g., "S01E05")
        public var episodeString: String? {
            guard season > 0 || episode > 0 else { return nil }
            return String(format: "S%02dE%02d", season, episode)
        }
    }
}

// MARK: - Renderer Discovery (Chromecast/AirPlay)

public extension VLCVideoPlayer {
    
    /// Renderer Discovery Manager for casting to external devices (Chromecast, AirPlay, etc.)
    class RendererDiscoveryManager: NSObject, ObservableObject {
        
        @Published public private(set) var availableRenderers: [RendererInfo] = []
        @Published public private(set) var isDiscovering: Bool = false
        @Published public private(set) var selectedRenderer: RendererInfo?
        
        private var discoverers: [VLCRendererDiscoverer] = []
        private weak var mediaPlayer: VLCMediaPlayer?
        private var isConfigured: Bool = false
        
        public struct RendererInfo: Identifiable, Equatable {
            public let id: String
            public let name: String
            public let iconURI: String?
            let rendererItem: VLCRendererItem
            
            public static func == (lhs: RendererInfo, rhs: RendererInfo) -> Bool {
                lhs.id == rhs.id
            }
        }
        
        override public init() {
            super.init()
        }
        
        deinit {
            stopDiscovery()
        }
        
        /// Configure the manager with a media player - must be called before connecting
        public func configure(with mediaPlayer: VLCMediaPlayer?) {
            self.mediaPlayer = mediaPlayer
            self.isConfigured = mediaPlayer != nil
        }
        
        /// Start discovering available renderers (Chromecast, etc.)
        public func startDiscovery() {
            // Can start discovery without a player configured
            guard !isDiscovering else { return }
            
            // Get available discoverer descriptions
            guard let descriptions = VLCRendererDiscoverer.list(), !descriptions.isEmpty else {
                print("[Renderer] No renderer discoverers available")
                return
            }
            
            DispatchQueue.main.async { [weak self] in
                self?.isDiscovering = true
                self?.availableRenderers = []
            }
            
            for description in descriptions {
                if let discoverer = VLCRendererDiscoverer(name: description.name) {
                    discoverer.delegate = self
                    if discoverer.start() {
                        discoverers.append(discoverer)
                        print("[Renderer] Started discoverer: \(description.longName)")
                    }
                }
            }
        }
        
        /// Stop renderer discovery
        public func stopDiscovery() {
            for discoverer in discoverers {
                discoverer.stop()
            }
            discoverers.removeAll()
            
            DispatchQueue.main.async { [weak self] in
                self?.isDiscovering = false
            }
        }
        
        /// Connect to a renderer
        @discardableResult
        public func connect(to renderer: RendererInfo) -> Bool {
            guard let mediaPlayer = mediaPlayer else {
                print("[Renderer] Cannot connect - mediaPlayer is nil. Call configure() first.")
                return false
            }
            
            let success = mediaPlayer.setRendererItem(renderer.rendererItem)
            if success {
                DispatchQueue.main.async { [weak self] in
                    self?.selectedRenderer = renderer
                }
                print("[Renderer] Connected to: \(renderer.name)")
            } else {
                print("[Renderer] Failed to connect to: \(renderer.name)")
            }
            return success
        }
        
        /// Disconnect from current renderer (play locally)
        public func disconnect() {
            _ = mediaPlayer?.setRendererItem(nil)
            DispatchQueue.main.async { [weak self] in
                self?.selectedRenderer = nil
            }
            print("[Renderer] Disconnected")
        }
        
        /// Get available discoverer names (for debugging)
        public var availableDiscovererNames: [String] {
            VLCRendererDiscoverer.list()?.map { $0.longName } ?? []
        }
        
        /// Check if a renderer is currently selected
        public var isConnected: Bool {
            selectedRenderer != nil
        }
    }
}

extension VLCVideoPlayer.RendererDiscoveryManager: VLCRendererDiscovererDelegate {
    
    public func rendererDiscovererItemAdded(_ rendererDiscoverer: VLCRendererDiscoverer, item: VLCRendererItem) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Check if renderer already exists (avoid duplicates)
            guard !self.availableRenderers.contains(where: { $0.name == item.name }) else {
                return
            }
            
            let info = VLCVideoPlayer.RendererDiscoveryManager.RendererInfo(
                id: item.name + "_" + UUID().uuidString,
                name: item.name,
                iconURI: item.iconURI,
                rendererItem: item
            )
            self.availableRenderers.append(info)
            print("[Renderer] Found: \(item.name)")
        }
    }
    
    public func rendererDiscovererItemDeleted(_ rendererDiscoverer: VLCRendererDiscoverer, item: VLCRendererItem) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            self.availableRenderers.removeAll { $0.name == item.name }
            
            // If the removed renderer was selected, clear selection
            if self.selectedRenderer?.name == item.name {
                self.selectedRenderer = nil
                print("[Renderer] Selected renderer was removed")
            }
            print("[Renderer] Removed: \(item.name)")
        }
    }
}

// MARK: - Transcoder Support

public extension VLCVideoPlayer {
    
    /// Transcoder for embedding subtitles into video files
    class SubtitleTranscoder: NSObject, ObservableObject {
        
        @Published public private(set) var isTranscoding: Bool = false
        @Published public private(set) var progress: String = ""
        
        private var transcoder: VLCTranscoder?
        
        public typealias TranscodeCompletion = (Bool, URL?) -> Void
        private var completion: TranscodeCompletion?
        
        override public init() {
            super.init()
        }
        
        /// Embed SRT subtitle into MP4 video, creating MKV output
        /// - Parameters:
        ///   - srtPath: Path to the SRT subtitle file
        ///   - mp4Path: Path to the MP4 video file
        ///   - outputPath: Path where the MKV output will be saved
        ///   - completion: Called when transcoding finishes with success status and output URL
        public func embedSubtitle(srtPath: String, mp4Path: String, outputPath: String, completion: @escaping TranscodeCompletion) {
            guard !isTranscoding else {
                completion(false, nil)
                return
            }
            
            self.completion = completion
            isTranscoding = true
            progress = "Starting transcoding..."
            
            let transcoder = VLCTranscoder()
            transcoder.delegate = self
            self.transcoder = transcoder
            
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let success = transcoder.reencodeAndMuxSRTFile(srtPath, toMP4File: mp4Path, outputPath: outputPath)
                
                DispatchQueue.main.async {
                    self?.isTranscoding = false
                    self?.progress = success ? "Completed" : "Failed"
                    completion(success, success ? URL(fileURLWithPath: outputPath) : nil)
                }
            }
        }
    }
}

extension VLCVideoPlayer.SubtitleTranscoder: VLCTranscoderDelegate {
    
    public func transcode(_ transcoder: VLCTranscoder, finishedSucessfully success: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.isTranscoding = false
            self?.progress = success ? "Completed" : "Failed"
        }
    }
}
