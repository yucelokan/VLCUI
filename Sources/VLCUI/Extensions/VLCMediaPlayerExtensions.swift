#if os(macOS)
import AppKit
#else
import UIKit
#endif

import VLCKit

extension VLCMediaPlayer {

    func setSubtitleSize(_ size: VLCVideoPlayer.ValueSelector<Int>) {
        let value: Int?

        switch size {
        case .auto:
            value = nil
        case let .absolute(size):
            value = size
        }

        #if !os(macOS)
        perform(
            Selector(("setTextRendererFontSize:")),
            with: value
        )
        #endif
    }

    func setSubtitleFont(_ font: VLCVideoPlayer.ValueSelector<_PlatformFont>) {
        switch font {
        case .auto:
            setSubtitleFont(_PlatformFont.defaultSubtitleFont.fontName)
        case let .absolute(font):
            setSubtitleFont(font.fontName)
        }
    }

    func setSubtitleFont(_ fontName: String) {
        #if !os(macOS)
        perform(
            Selector(("setTextRendererFont:")),
            with: fontName
        )
        #endif
    }

    func setSubtitleColor(_ color: VLCVideoPlayer.ValueSelector<_PlatformColor>) {
        let value: UInt

        switch color {
        case .auto:
            value = _PlatformColor.white.hex
        case let .absolute(fontColor):
            value = fontColor.hex
        }

        #if !os(macOS)
        perform(
            Selector(("setTextRendererFontColor:")),
            with: value
        )
        #endif
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
