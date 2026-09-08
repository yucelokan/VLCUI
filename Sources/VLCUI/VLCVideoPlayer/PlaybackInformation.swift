import Foundation
import VLCKitSPM

public extension VLCVideoPlayer {

    struct PlaybackInformation {
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
