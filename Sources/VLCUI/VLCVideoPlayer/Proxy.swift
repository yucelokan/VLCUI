import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

import VLCKitSPM

public extension VLCVideoPlayer {

    class Proxy: ObservableObject {

        weak var mediaPlayer: VLCMediaPlayer?
        weak var videoPlayerView: UIVLCVideoPlayerView?

        @MainActor
        private var thumbnailHandlers = Set<ThumbnailHandler>()

        public init() {
            self.mediaPlayer = nil
            self.videoPlayerView = nil
        }
        
        /// Returns the actual VLC drawable view for PiP setup
        /// This is the view that VLC renders video to (not the container)
        #if !os(macOS)
        public var videoContentView: UIView? {
            return videoPlayerView?.vlcDrawableView
        }
        #endif
        
        /// Returns the current video size from VLC media player
        public var videoSize: CGSize {
            return mediaPlayer?.videoSize ?? CGSize(width: 1920, height: 1080)
        }

        /// Current libVLC counters, independent of state/time delegate delivery.
        /// During remote header parsing or a resume seek the input may advance
        /// without any time notification. This reads the bound media only; it
        /// never opens a second connection or requests metadata parsing.
        @MainActor
        public var statisticsSnapshot: VLCVideoPlayer.Statistics? {
            guard let media = mediaPlayer?.media else { return nil }
            return .init(stats: media.statistics)
        }
        
        /// Captures a snapshot of the current video frame and returns it as UIImage
        /// This is useful for PiP frame capture as it bypasses GPU rendering
        #if !os(macOS)
        public func captureCurrentFrame() -> UIImage? {
            guard let mediaPlayer = mediaPlayer else { return nil }
            
            let videoSize = mediaPlayer.videoSize
            guard videoSize.width > 0 && videoSize.height > 0 else { return nil }
            
            // Create temp path for snapshot
            let tempPath = NSTemporaryDirectory() + "vlc_pip_frame.png"
            
            // Remove old file if exists
            try? FileManager.default.removeItem(atPath: tempPath)
            
            // Save snapshot
            mediaPlayer.saveVideoSnapshot(
                at: tempPath,
                withWidth: Int32(videoSize.width),
                andHeight: Int32(videoSize.height)
            )
            
            // Read and return image
            if let data = try? Data(contentsOf: URL(fileURLWithPath: tempPath)),
               let image = UIImage(data: data) {
                // Clean up
                try? FileManager.default.removeItem(atPath: tempPath)
                return image
            }
            
            return nil
        }
        #endif

        /// Play the current media.
        public func play() {
            mediaPlayer?.play()
        }

        /// Pause the current media.
        public func pause() {
            mediaPlayer?.pause()
        }

        /// Stop the current media.
        ///
        /// - Important: This calls into libVLC synchronously on the calling thread.
        ///   `-stop` can block for a noticeable amount of time (or, on a stalled
        ///   network stream, much longer) while libVLC tears down its internal
        ///   demux/decode/audio-output threads. Prefer `stopAsync()` from any
        ///   context where blocking the caller (e.g. the main thread) isn't
        ///   acceptable, which is effectively always true from app teardown paths.
        public func stop() {
            mediaPlayer?.stop()
        }

        /// Stops the current media without blocking the calling thread.
        ///
        /// Serialized with retirement for this player only. Do not issue play
        /// while this stop is pending. Use retireAsync() for terminal teardown.
        public func stopAsync() {
            guard let player = mediaPlayer else { return }
            VLCMediaPlayerTeardown.stop(player)
        }

        /// Silences and unbinds immediately, then stops off-main. To play again,
        /// create a fresh session with playNewMedia instead of reusing this one.
        @MainActor
        public func retireAsync() {
            videoPlayerView?.retireCurrentMediaPlayer()
        }

        @MainActor
        public func setVolume(_ volume: Int32) {
            mediaPlayer?.audio?.volume = volume
        }

        /// Jump forward a given amount of seconds.
        @available(iOS, deprecated: 16.0, message: "Use `Duration` typed functions instead")
        @available(tvOS, deprecated: 16.0, message: "Use `Duration` typed functions instead")
        @available(macOS, deprecated: 13.0, message: "Use `Duration` typed functions instead")
        public func jumpForward(_ seconds: Int) {
            let remainingTime = -(mediaPlayer?.remainingTime?.intValue ?? 0)

            guard remainingTime > 0 else { return }

            if remainingTime < seconds.asInt32 * 1000 {
                mediaPlayer?.time = mediaPlayer?.media?.length ?? VLCTime(int: 0)
            } else {
                mediaPlayer?.jumpForward(seconds.asInt32)
            }
        }

        /// Jump backward a given amount of seconds.
        @available(iOS, deprecated: 16.0, message: "Use `Duration` typed functions instead")
        @available(tvOS, deprecated: 16.0, message: "Use `Duration` typed functions instead")
        @available(macOS, deprecated: 13.0, message: "Use `Duration` typed functions instead")
        public func jumpBackward(_ seconds: Int) {
            let currentTime = mediaPlayer?.time.intValue ?? 0

            if seconds.asInt32 > currentTime {
                mediaPlayer?.time = VLCTime(int: 0)
            } else {
                mediaPlayer?.jumpBackward(seconds.asInt32)
            }
        }

        /// Jump forward a given duration.
        @available(iOS 16.0, macOS 13.0, tvOS 16.0, *)
        public func jumpForward(_ seconds: Duration) {
            let remainingTime = Duration.milliseconds(-(mediaPlayer?.remainingTime?.intValue ?? 0))

            guard remainingTime > .zero else { return }

            if remainingTime < seconds {
                mediaPlayer?.time = mediaPlayer?.media?.length ?? VLCTime(int: 0)
            } else {
                mediaPlayer?.jumpForward(Int32(seconds.components.seconds))
            }
        }

        /// Jump backward a given duration.
        @available(iOS 16.0, macOS 13.0, tvOS 16.0, *)
        public func jumpBackward(_ seconds: Duration) {
            let currentTime = Duration.milliseconds(mediaPlayer?.time.intValue ?? 0)

            if seconds > currentTime {
                mediaPlayer?.time = VLCTime(int: 0)
            } else {
                mediaPlayer?.jumpBackward(Int32(seconds.components.seconds))
            }
        }

        /// Go to the next frame.
        ///
        /// - Important: media will be paused.
        public func gotoNextFrame() {
            mediaPlayer?.gotoNextFrame()
        }

        /// Set the subtitle track index
        ///
        /// - Important: If there is no valid track with the given index, the track will default to disabled.
        public func setSubtitleTrack(_ index: ValueSelector<Int>) {
            guard let mediaPlayer else { return }
            let newTrackIndex = mediaPlayer.subtitleTrackIndex(from: index)
            mediaPlayer.currentVideoSubTitleIndex = newTrackIndex.asInt32
        }

        /// Set the audio track index.
        ///
        /// - Important: If there is no valid track with the given index, the track will default to disabled.
        /// Set the audio track index.
        ///
        /// - Important: If there is no valid track with the given index, the track will default to disabled.
        public func setAudioTrack(_ index: ValueSelector<Int>) {
            guard let mediaPlayer else { return }
            let newTrackIndex = mediaPlayer.audioTrackIndex(from: index)
            mediaPlayer.currentAudioTrackIndex = newTrackIndex.asInt32
        }

        /// Set the video track index.
        ///
        /// - Important: If there is no valid track with the given index, the track will default to disabled.
        public func setVideoTrack(_ index: ValueSelector<Int>) {
            guard let mediaPlayer else { return }
            let newTrackIndex = mediaPlayer.videoTrackIndex(from: index)
            mediaPlayer.currentVideoTrackIndex = newTrackIndex.asInt32
        }

        /// Set the subtitle delay
        @available(iOS, deprecated: 16.0, message: "Use `Duration` typed functions instead")
        @available(tvOS, deprecated: 16.0, message: "Use `Duration` typed functions instead")
        @available(macOS, deprecated: 13.0, message: "Use `Duration` typed functions instead")
        public func setSubtitleDelay(_ interval: TimeSelector) {
            let delay = interval.asTicks * 1000
            mediaPlayer?.currentVideoSubTitleDelay = delay
        }

        /// Set the audio delay
        @available(iOS, deprecated: 16.0, message: "Use `Duration` typed functions instead")
        @available(tvOS, deprecated: 16.0, message: "Use `Duration` typed functions instead")
        @available(macOS, deprecated: 13.0, message: "Use `Duration` typed functions instead")
        public func setAudioDelay(_ interval: TimeSelector) {
            let delay = interval.asTicks * 1000
            mediaPlayer?.currentAudioPlaybackDelay = delay
        }

        /// Set the player rate
        public func setRate(_ rate: ValueSelector<Float>) {
            guard let mediaPlayer else { return }
            let newRate = mediaPlayer.rate(from: rate)
            mediaPlayer.fastForward(atRate: newRate)
        }

        /// Set the player time.
        @available(iOS, deprecated: 16.0, message: "Use `Duration` typed functions instead")
        @available(tvOS, deprecated: 16.0, message: "Use `Duration` typed functions instead")
        @available(macOS, deprecated: 13.0, message: "Use `Duration` typed functions instead")
        public func setTime(_ time: TimeSelector) {
            guard let mediaPlayer,
                  let media = mediaPlayer.media else { return }

            guard time.asTicks >= 0 && time.asTicks <= media.length.intValue else { return }
            mediaPlayer.time = VLCTime(int: time.asTicks.asInt32)
        }

        /// Set the subtitle delay
        @available(iOS 16.0, macOS 13.0, tvOS 16.0, *)
        public func setSubtitleDelay(_ seconds: Duration) {
            mediaPlayer?.currentVideoSubTitleDelay = Int(seconds.microseconds)
        }

        /// Set the audio delay
        @available(iOS 16.0, macOS 13.0, tvOS 16.0, *)
        public func setAudioDelay(_ seconds: Duration) {
            mediaPlayer?.currentAudioPlaybackDelay = Int(seconds.microseconds)
        }

        /// Set the player time.
        @available(iOS 16.0, macOS 13.0, tvOS 16.0, *)
        public func setSeconds(_ seconds: Duration) {
            guard let mediaPlayer,
                  let media = mediaPlayer.media else { return }

            guard seconds <= media.duration else { return }

            mediaPlayer.time = VLCTime(int: Int32(seconds.milliseconds))
        }

        #if !os(macOS)
        /// Aspect fill depending on the video's content size and the view's bounds, based
        /// on the given percentage of completion.
        public func aspectFill(_ percentage: Float) {
            videoPlayerView?.setAspectFill(with: percentage)
        }

        /// Set the media subtitle size
        ///
        /// - Important: Due to VLCKit, a given size does not accurately represent a font size and magnitudes are inverted.
        /// Larger values indicate a smaller font and smaller values indicate a larger font.
        public func setSubtitleSize(_ size: ValueSelector<Int>) {
            mediaPlayer?.setSubtitleSize(size)
        }

        /// Set the subtitle font using the font name of the given `UIFont`.
        public func setSubtitleFont(_ font: ValueSelector<_PlatformFont>) {
            mediaPlayer?.setSubtitleFont(font)
        }

        /// Set the subtitle font using the given font name.
        public func setSubtitleFont(_ fontName: String) {
            mediaPlayer?.setSubtitleFont(fontName)
        }

        /// Set the subtitle font color using the RGB values of the given `UIColor`.
        public func setSubtitleColor(_ color: ValueSelector<_PlatformColor>) {
            mediaPlayer?.setSubtitleColor(color)
        }
        #endif

        /// Add a playback child.
        public func addPlaybackChild(_ child: PlaybackChild) {
            mediaPlayer?.addPlaybackSlave(child.url, type: child.type.asVLCSlaveType, enforce: child.enforce)
        }

        /// Play new media given a configuration.
        public func playNewMedia(_ newConfiguration: Configuration) {
            videoPlayerView?.setupVLCMediaPlayer(with: newConfiguration)
        }

        /// Saves a snapshot of the current media.
        /// File names are automatically generated by VLCKit.
        ///
        /// - Parameter atPath: The directory path where the snapshot will be saved.
        public func saveSnapshot(atPath path: String) {
            guard let mediaPlayer else { return }

            let videoSize = mediaPlayer.videoSize

            mediaPlayer.saveVideoSnapshot(
                at: path,
                withWidth: Int32(videoSize.width),
                andHeight: Int32(videoSize.height)
            )
        }

        /// Starts the recording process.
        ///
        /// - Parameter atPath: The directory path where the recording will be saved
        public func startRecording(atPath path: String) {
            mediaPlayer?.startRecording(atPath: path)
        }

        /// Stops the recording process.
        public func stopRecording() {
            mediaPlayer?.stopRecording()
        }

        /// Fetches a thumbnail image from the media at the given position.
        ///
        /// - Parameter position: The position in the media to take the snapshot at, as a percentage (0.0 to 1.0).
        /// - Parameter size: The size of the image to be captured.
        /// - Returns: `NSImage` or `UIImage` of the thumbnail.
        /// - Throws: `VLCVideoPlayer.ThumbnailError` if an error occurs.
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

        /// Set the video aspect ratio
        ///
        /// - Parameter ratio: The aspect ratio to set using an `AspectRatio` value.
        public func setAspectRatio(_ ratio: VLCVideoPlayer.AspectRatio) {
            guard ratio != .default else {
                mediaPlayer?.videoAspectRatio = nil
                return
            }

            ratio.rawValue.withCString { cString in
                mediaPlayer?.videoAspectRatio = UnsafeMutablePointer(mutating: cString)
            }
        }

        /// Applies VLC's Adjust video filter in real-time via MobileVLCKit's VLCAdjustFilter.
        ///
        /// Ranges (from libvlc adjust.c):
        ///   - contrast:   0.0–2.0   (default 1.0)
        ///   - brightness: 0.0–2.0   (default 1.0)
        ///   - hue:       -180–180   (default 0)
        ///   - saturation: 0.0–3.0   (default 1.0)
        ///   - gamma:     0.01–10.0  (default 1.0)
        public func applyVideoAdjust(
            contrast: Float,
            brightness: Float,
            hue: Float,
            saturation: Float,
            gamma: Float
        ) {
            guard let player = mediaPlayer else { return }
            let filter = player.adjustFilter

            let isDefault = contrast == 1.0
                && brightness == 1.0
                && hue == 0.0
                && saturation == 1.0
                && gamma == 1.0

            if isDefault {
                if filter.isEnabled {
                    _ = filter.resetParametersIfNeeded()
                    filter.isEnabled = false
                }
                return
            }

            filter.contrast.value = NSNumber(value: contrast)
            filter.brightness.value = NSNumber(value: brightness)
            filter.hue.value = NSNumber(value: hue)
            filter.saturation.value = NSNumber(value: saturation)
            filter.gamma.value = NSNumber(value: gamma)
            filter.isEnabled = true
        }
    }
}
