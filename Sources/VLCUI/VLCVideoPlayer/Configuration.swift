#if os(macOS)
import AppKit
#else
import UIKit
#endif

public extension VLCVideoPlayer {

    /// Configuration for VLCMediaPlayer
    struct Configuration {
        /// Original media identity, preserved in diagnostics and playback information.
        public var url: URL
        /// Resolves the playback URL once per actual player creation, including
        /// replacements and replay, after retiring the previous player. Keep this
        /// synchronous factory lightweight; do not perform network work here.
        /// Nil plays `url` directly without changing existing client behavior.
        public var mediaURLProvider: (() -> URL)?
        public var autoPlay: Bool
        /// Applied before play(), including replacement/replay players. Nil keeps
        /// libVLC's default; clients resolving tracks asynchronously can start at zero.
        public var initialVolume: Int32?
        /// Opt-in, bounded, privacy-allowlisted libVLC pipeline diagnostics.
        /// Shared-library events are observations, never recovery commands.
        public var startupDiagnosticsEnabled: Bool

        @available(iOS, deprecated: 16.0, message: "Use `startSeconds` instead")
        @available(tvOS, deprecated: 16.0, message: "Use `startSeconds` instead")
        @available(macOS, deprecated: 13.0, message: "Use `startSeconds` instead")
        public var startTime: TimeSelector

        public var aspectFill: Bool
        public var replay: Bool
        public var rate: ValueSelector<Float>
        public var subtitleIndex: ValueSelector<Int>
        public var audioIndex: ValueSelector<Int>
        public var subtitleSize: ValueSelector<Int>
        public var subtitleFont: ValueSelector<_PlatformFont>
        public var subtitleColor: ValueSelector<_PlatformColor>
        public var playbackChildren: [PlaybackChild]
        public var options: [String: Any]

        @available(macOS, deprecated: 13.0, message: "Use init with `startSeconds` instead")
        @_disfavoredOverload
        public init(
            url: URL,
            autoPlay: Bool = true,
            startTime: TimeSelector = .ticks(0),
            aspectFill: Bool = false,
            replay: Bool = false,
            rate: ValueSelector<Float> = .auto,
            subtitleIndex: ValueSelector<Int> = .auto,
            audioIndex: ValueSelector<Int> = .auto,
            subtitleSize: ValueSelector<Int> = .auto,
            subtitleFont: ValueSelector<_PlatformFont> = .auto,
            subtitleColor: ValueSelector<_PlatformColor> = .auto,
            playbackChildren: [PlaybackChild] = [],
            options: [String: Any] = [:],
            initialVolume: Int32? = nil,
            startupDiagnosticsEnabled: Bool = false,
            mediaURLProvider: (() -> URL)? = nil
        ) {
            self.url = url
            self.mediaURLProvider = mediaURLProvider
            self.autoPlay = autoPlay
            self.initialVolume = initialVolume
            self.startupDiagnosticsEnabled = startupDiagnosticsEnabled
            self.startTime = startTime
            self.aspectFill = aspectFill
            self.replay = replay
            self.rate = rate
            self.subtitleIndex = subtitleIndex
            self.audioIndex = audioIndex
            self.subtitleSize = subtitleSize
            self.subtitleFont = subtitleFont
            self.subtitleColor = subtitleColor
            self.playbackChildren = playbackChildren
            self.options = options
        }

        @available(iOS 16.0, macOS 13.0, tvOS 16.0, *)
        public init(
            url: URL,
            autoPlay: Bool = true,
            startSeconds: Duration = .zero,
            aspectFill: Bool = false,
            replay: Bool = false,
            rate: ValueSelector<Float> = .auto,
            subtitleIndex: ValueSelector<Int> = .auto,
            audioIndex: ValueSelector<Int> = .auto,
            subtitleSize: ValueSelector<Int> = .auto,
            subtitleFont: ValueSelector<_PlatformFont> = .auto,
            subtitleColor: ValueSelector<_PlatformColor> = .auto,
            playbackChildren: [PlaybackChild] = [],
            options: [String: Any] = [:],
            initialVolume: Int32? = nil,
            startupDiagnosticsEnabled: Bool = false,
            mediaURLProvider: (() -> URL)? = nil
        ) {
            self.url = url
            self.mediaURLProvider = mediaURLProvider
            self.autoPlay = autoPlay
            self.initialVolume = initialVolume
            self.startupDiagnosticsEnabled = startupDiagnosticsEnabled
            self.startTime = .ticks(Int(startSeconds.milliseconds))
            self.aspectFill = aspectFill
            self.replay = replay
            self.rate = rate
            self.subtitleIndex = subtitleIndex
            self.audioIndex = audioIndex
            self.subtitleSize = subtitleSize
            self.subtitleFont = subtitleFont
            self.subtitleColor = subtitleColor
            self.playbackChildren = playbackChildren
            self.options = options
        }

        @available(iOS 16.0, macOS 13.0, tvOS 16.0, *)
        public var startSeconds: Duration {
            get {
                Duration.milliseconds(startTime.asTicks)
            }
            set {
                startTime = .ticks(Int(newValue.milliseconds))
            }
        }
    }
}
