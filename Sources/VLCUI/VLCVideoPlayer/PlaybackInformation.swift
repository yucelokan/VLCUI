import Foundation

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
        public let subtitleTracks: [MediaTrack]
        public let audioTracks: [MediaTrack]

        // VLCKit 4.0 removed direct media statistics properties
        // These are now available via VLCMediaStats struct
        public let numberOfReadBytesOnInput: Int
        public let inputBitrate: Float
        public let numberOfReadBytesOnDemux: Int
        public let demuxBitrate: Float
        public let numberOfDecodedVideoBlocks: Int
        public let numberOfDecodedAudioBlocks: Int
        public let numberOfDisplayedPictures: Int
        public let numberOfLostPictures: Int
        public let numberOfPlayedAudioBuffers: Int
        public let numberOfLostAudioBuffers: Int
        public let numberOfSentPackets: Int
        public let numberOfSentBytes: Int
        public let streamOutputBitrate: Float
        public let numberOfCorruptedDataPackets: Int
        public let numberOfDiscontinuties: Int
        
        // VLCKit 4.0 compatible initializer with default values for statistics
        init(
            startConfiguration: VLCVideoPlayer.Configuration,
            position: Float,
            length: Int,
            isSeekable: Bool,
            playbackRate: Float,
            videoSize: CGSize,
            currentSubtitleTrack: MediaTrack,
            currentAudioTrack: MediaTrack,
            subtitleTracks: [MediaTrack],
            audioTracks: [MediaTrack],
            numberOfReadBytesOnInput: Int = 0,
            inputBitrate: Float = 0,
            numberOfReadBytesOnDemux: Int = 0,
            demuxBitrate: Float = 0,
            numberOfDecodedVideoBlocks: Int = 0,
            numberOfDecodedAudioBlocks: Int = 0,
            numberOfDisplayedPictures: Int = 0,
            numberOfLostPictures: Int = 0,
            numberOfPlayedAudioBuffers: Int = 0,
            numberOfLostAudioBuffers: Int = 0,
            numberOfSentPackets: Int = 0,
            numberOfSentBytes: Int = 0,
            streamOutputBitrate: Float = 0,
            numberOfCorruptedDataPackets: Int = 0,
            numberOfDiscontinuties: Int = 0
        ) {
            self.startConfiguration = startConfiguration
            self.position = position
            self.length = length
            self.isSeekable = isSeekable
            self.playbackRate = playbackRate
            self.videoSize = videoSize
            self.currentSubtitleTrack = currentSubtitleTrack
            self.currentAudioTrack = currentAudioTrack
            self.subtitleTracks = subtitleTracks
            self.audioTracks = audioTracks
            self.numberOfReadBytesOnInput = numberOfReadBytesOnInput
            self.inputBitrate = inputBitrate
            self.numberOfReadBytesOnDemux = numberOfReadBytesOnDemux
            self.demuxBitrate = demuxBitrate
            self.numberOfDecodedVideoBlocks = numberOfDecodedVideoBlocks
            self.numberOfDecodedAudioBlocks = numberOfDecodedAudioBlocks
            self.numberOfDisplayedPictures = numberOfDisplayedPictures
            self.numberOfLostPictures = numberOfLostPictures
            self.numberOfPlayedAudioBuffers = numberOfPlayedAudioBuffers
            self.numberOfLostAudioBuffers = numberOfLostAudioBuffers
            self.numberOfSentPackets = numberOfSentPackets
            self.numberOfSentBytes = numberOfSentBytes
            self.streamOutputBitrate = streamOutputBitrate
            self.numberOfCorruptedDataPackets = numberOfCorruptedDataPackets
            self.numberOfDiscontinuties = numberOfDiscontinuties
        }
    }
}
