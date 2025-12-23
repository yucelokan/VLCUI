#if os(macOS)
import AppKit
#else
import UIKit
#endif

import VLCKit

extension VLCMediaPlayer {

    /// VLCKit 4.0: Use currentSubTitleFontScale property
    /// The scale is relative where 1.0 is the default size
    func setSubtitleSize(_ size: VLCVideoPlayer.ValueSelector<Int>) {
        switch size {
        case .auto:
            currentSubTitleFontScale = 1.0
        case let .absolute(sizeValue):
            // Convert from the old VLC freetype-fontsize (inverted scale)
            // to the new scale (1.0 = default, >1 = bigger, <1 = smaller)
            // Old: 16-72 where smaller number = bigger font
            // New: scale where 1.0 = default
            // If sizeValue is like old freetype (16=big, 72=small), convert it
            // Assume default was ~44, so scale = 44.0 / sizeValue
            let scale = 44.0 / max(Float(sizeValue), 1.0)
            currentSubTitleFontScale = scale
        }
    }

    /// VLCKit 4.0: Font must be set via media options before playback
    /// This function has limited effect during playback
    func setSubtitleFont(_ font: VLCVideoPlayer.ValueSelector<_PlatformFont>) {
        // In VLCKit 4.0, subtitle font must be set via media options before playback
        // This method is kept for API compatibility but may not work during playback
        switch font {
        case .auto:
            break
        case let .absolute(fontValue):
            _ = fontValue.fontName // Font name would be set via --freetype-font option
        }
    }

    func setSubtitleFont(_ fontName: String) {
        // In VLCKit 4.0, this must be set via media options before playback
        // Options like --freetype-font should be added to VLCMedia
        _ = fontName
    }

    /// VLCKit 4.0: Color must be set via media options before playback
    func setSubtitleColor(_ color: VLCVideoPlayer.ValueSelector<_PlatformColor>) {
        // In VLCKit 4.0, subtitle color must be set via media options before playback
        // Use --freetype-color option when creating the media
        switch color {
        case .auto:
            break
        case let .absolute(colorValue):
            _ = colorValue.hex // Color would be set via --freetype-color option
        }
    }

    // VLCKit 4.0: Use textTracks instead of videoSubTitlesIndexes
    func subtitleTrackIndex(from track: VLCVideoPlayer.ValueSelector<Int>) -> Int {
        let textTracks = self.textTracks
        guard !textTracks.isEmpty else { return -1 }
        
        switch track {
        case .auto:
            // Return the first available text track index
            return Int(textTracks.first?.identifier ?? -1)
        case let .absolute(index):
            // Check if the requested index exists
            if textTracks.contains(where: { Int($0.identifier) == index }) {
                return index
            }
            return -1
        }
    }

    // VLCKit 4.0: Use audioTracks
    func audioTrackIndex(from track: VLCVideoPlayer.ValueSelector<Int>) -> Int {
        let audioTracks = self.audioTracks
        guard !audioTracks.isEmpty else { return -1 }
        
        switch track {
        case .auto:
            // Return the first available audio track index
            return Int(audioTracks.first?.identifier ?? -1)
        case let .absolute(index):
            // Check if the requested index exists
            if audioTracks.contains(where: { Int($0.identifier) == index }) {
                return index
            }
            return -1
        }
    }

    func rate(from rate: VLCVideoPlayer.ValueSelector<Float>) -> Float {
        switch rate {
        case .auto:
            return 1
        case let .absolute(speed):
            return speed
        }
    }
    
    // VLCKit 4.0: Select text track by index
    func selectTextTrack(at index: Int) {
        for track in textTracks {
            if Int(track.identifier) == index {
                track.isSelected = true
            } else {
                track.isSelected = false
            }
        }
    }
    
    // VLCKit 4.0: Select audio track by index
    func selectAudioTrack(at index: Int) {
        for track in audioTracks {
            if Int(track.identifier) == index {
                track.isSelected = true
            } else {
                track.isSelected = false
            }
        }
    }
    
    // VLCKit 4.0: Get currently selected text track
    var currentTextTrackIndex: Int {
        return Int(textTracks.first(where: { $0.isSelected })?.identifier ?? -1)
    }
    
    // VLCKit 4.0: Get currently selected audio track
    var currentAudioTrackIdx: Int {
        return Int(audioTracks.first(where: { $0.isSelected })?.identifier ?? -1)
    }
}
