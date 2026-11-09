import Darwin
import Foundation
import UIKit

/// The libVLC the app actually loaded. The two VLCUI revisions import VLCKit under different module names
/// (`VLCKitSPM` for 3.7.4, `VLCKit` for 4.0), so the host reads `VLCLibrary` through the Objective-C runtime and
/// imports neither. Asking for the shared library also creates it, so its start-up cost stays out of the first start.
enum LibraryInfo {

    struct Report {
        let version: String?
        let changeset: String?
        let vlckitVersion: String?
    }

    private typealias ClassGetter = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?

    static func load() -> Report {
        let selector = NSSelectorFromString("sharedLibrary")
        guard let libraryClass = NSClassFromString("VLCLibrary"),
              let method = class_getClassMethod(libraryClass, selector),
              let library = unsafeBitCast(method_getImplementation(method), to: ClassGetter.self)(libraryClass, selector)?
              .takeUnretainedValue() as? NSObject
        else {
            return Report(version: nil, changeset: nil, vlckitVersion: nil)
        }
        let bundle = Bundle(for: libraryClass)
        let vlckit = bundle == Bundle.main ? nil : bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return Report(
            version: string(library, "version"),
            changeset: string(library, "changeset"),
            vlckitVersion: vlckit
        )
    }

    private static func string(_ object: NSObject, _ key: String) -> String? {
        guard object.responds(to: NSSelectorFromString(key)) else { return nil }
        return object.value(forKey: key) as? String
    }
}

/// VLCUI's `State` keeps VLCKit 3's order (stopped, opening, buffering, ended, error, playing, paused, esAdded). The
/// `vlckit-4.0` revision wraps VLCKit 4's state by raw value, and VLCKit 4 numbers its states differently (stopped,
/// stopping, opening, buffering, error, playing, paused). So on 4.0 VLCUI reports buffering as `.ended` and opening as
/// `.buffering`. The host names each state as the engine meant it, and counts stalls and errors from that.
enum EngineState {

    private static let vlckit3 = ["stopped", "opening", "buffering", "ended", "error", "playing", "paused", "esAdded"]
    private static let vlckit4 = ["stopped", "stopping", "opening", "buffering", "error", "playing", "paused", "esAdded"]

    static func name(of rawValue: Int, generation: Int) -> String {
        let names = generation >= 4 ? vlckit4 : vlckit3
        return names.indices.contains(rawValue) ? names[rawValue] : "unknown\(rawValue)"
    }
}

/// The process's physical footprint, the number Xcode's memory gauge and jetsam use.
enum Footprint {

    static func current() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }
}

/// Samples the footprint every 100 ms off the main thread and keeps the peak since the last reset.
final class FootprintSampler {

    private let queue = DispatchQueue(label: "benchmark.footprint", qos: .utility)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var peakBytes: UInt64 = 0

    func start() {
        reset()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.sample() }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func reset() {
        lock.lock()
        peakBytes = Footprint.current() ?? 0
        lock.unlock()
    }

    var peak: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return peakBytes
    }

    private func sample() {
        guard let value = Footprint.current() else { return }
        lock.lock()
        peakBytes = max(peakBytes, value)
        lock.unlock()
    }
}

/// The app's default VLC media options: `NAPlayerViewModel.buildCommonVLCOptions` (wuwtv `release/1.2.5`) with
/// `NAPlayerSettings.default`, a stream without playback headers, and no software-decoding fallback.
///
/// | Option | Value | Source |
/// | --- | --- | --- |
/// | `network-caching` | 1500 | `settings.networkCaching` |
/// | `adaptive-logic` | `highest` | `NAVLCAdaptiveStartupQuality.default` |
/// | `avcodec-hw` | `any` | `settings.hardwareDecoding` (true) |
/// | `clock-jitter`, `clock-synchro` | 0 | fixed |
/// | (no `deinterlace`) | | `settings.deinterlace` 0 (off) |
/// | (no `aspect-ratio`) | | `NAPlayerAspectRatio.default` |
/// | `text-renderer` | `freetype` | `NAVLCConfigurationFactory.applySubtitleOptions` |
/// | `freetype-rel-fontsize` | 20 | `NAVLCSubtitleStyle.vlcSize(for: 100)` |
/// | `freetype-font` | `Verdana` | font "System" resolves to Verdana |
/// | `freetype-color` | 16777215 | `color_white` |
/// | `subsdec-encoding` | `UTF-8` | `settings.subtitleEncoding` |
enum AppDefaultOptions {

    static let options: [String: Any] = [
        "network-caching": 1500,
        "adaptive-logic": "highest",
        "avcodec-hw": "any",
        "clock-jitter": 0,
        "clock-synchro": 0,
        "text-renderer": "freetype",
        "freetype-rel-fontsize": 20,
        "freetype-font": subtitleFont.fontName,
        "freetype-color": 0xFFFFFF,
        "subsdec-encoding": "UTF-8",
    ]

    /// The configuration values the app passes next to the options (`NAVLCConfigurationFactory.make`).
    static let subtitleSize = 20
    static let subtitleFont = UIFont(name: "Verdana", size: 14) ?? UIFont.systemFont(ofSize: 14)
    static let subtitleColor = UIColor.white

    static var described: [String: String] {
        options.mapValues { "\($0)" }
    }
}
