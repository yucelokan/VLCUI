import Foundation
import VLCKitSPM

/// Serializes every off-main-thread `VLCMediaPlayer.stop()` / release for the whole
/// library behind a single dedicated **serial** queue.
///
/// There are two independent places that can end up telling a `VLCMediaPlayer` to
/// stop right as a session ends: an app calling `Proxy.stop()` (e.g. as part of its
/// own dismiss/teardown flow) and `UIVLCVideoPlayerView`'s `deinit`, which releases
/// its own strong reference off-main. Both used to hop onto
/// `DispatchQueue.global(qos: .utility)` independently — a *concurrent* queue, so two
/// worker threads could end up calling into libVLC for the *same* underlying
/// `VLCMediaPlayer` at the same time (one via the (weak) `Proxy.mediaPlayer`, one via
/// the view's own strong `currentMediaPlayer`). libVLC's C API is not documented as
/// safe to call concurrently from two threads for the same instance, and this race
/// is a plausible cause of the exact same "stuck in `pthread_join` inside
/// `libvlc_media_player_destroy`" hang persisting even after moving the call off the
/// main thread: the *destination* thread changed, but two of them could still pile up
/// on the same player at once.
///
/// Routing every such call through this one serial queue guarantees at most one
/// `stop()`/release is ever in flight for any player at a time, while still keeping
/// all of it off the main thread.
enum VLCMediaPlayerTeardown {

    static let queue = DispatchQueue(label: "org.vlcui.mediaplayer.teardown", qos: .utility)
}
