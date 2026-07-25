import Foundation
import VLCKitSPM

/// Owns the end-of-life teardown of `VLCMediaPlayer` instances so that
/// `-[VLCMediaPlayer dealloc]` — and its blocking `pthread_join` inside
/// `libvlc_media_player_destroy` — can NEVER run on the main thread.
///
/// ## Why simply releasing on a background queue is not enough
///
/// A confirmed device thread dump showed the main thread frozen in:
///
///     __ulock_wait <- _pthread_join <- libvlc_media_player_destroy
///     <- libvlc_media_player_release <- -[VLCAudio dealloc]
///     <- -[VLCMediaPlayer .cxx_destruct] <- -[VLCMediaPlayer dealloc]
///     <- _call_dispose_helpers_excp        // <-- a *block* dispose released the last ref
///
/// The `_call_dispose_helpers_excp` frame is the smoking gun: the last strong
/// reference was dropped by the Blocks runtime disposing a heap block on the main
/// thread — NOT by our code. VLCKit dispatches state/time/event notifications to the
/// main queue as blocks that strongly retain the `VLCMediaPlayer` (via its internal
/// events handler). So even when the view/app hands its own last reference to a
/// background queue, a pending event block already sitting in the main queue can
/// outlive it; when that block finishes and is disposed on the main thread, THAT
/// release becomes the last one, and `dealloc`'s blocking join runs on the main
/// thread anyway — a 1–2s freeze in the common case, a watchdog kill when libVLC's
/// internal thread is stuck on a dead network read.
///
/// ## What `retire(_:)` guarantees
///
/// 1. All stop/teardown calls into libVLC are serialized on one dedicated **serial**
///    queue (`queue`) — shared with `Proxy.stopAsync()` — so no two threads ever call
///    into the same player concurrently.
/// 2. The retired player is held strongly (in `retiring`) while:
///    a. `stop()` runs on the teardown queue, then
///    b. a no-op hop through the **main** queue drains every event block VLCKit had
///       already enqueued there (main is FIFO: they run — and are disposed, dropping
///       their retains — before our hop executes, no matter how congested main is), then
///    c. a grace period on the teardown queue absorbs any final stragglers dispatched
///       right around `stop()` returning.
/// 3. Only then is our reference dropped — on the teardown queue — making it the last
///    one by construction, so `dealloc`/`libvlc_media_player_destroy`/`pthread_join`
///    all run on this background queue and can take as long as they need without ever
///    touching the main thread.
enum VLCMediaPlayerTeardown {

    static let queue = DispatchQueue(label: "org.vlcui.mediaplayer.teardown", qos: .utility)

    /// Strong references to players currently being retired.
    /// Only ever read/mutated on `queue`.
    private static var retiring: [ObjectIdentifier: VLCMediaPlayer] = [:]

    /// How long to keep holding the player after the main-queue drain, to absorb
    /// event blocks VLCKit dispatches right around `stop()` returning.
    private static let graceInterval: TimeInterval = 1.0

    /// Stops `player` and guarantees its final release (and therefore its blocking
    /// `dealloc`) happens on the teardown queue — never on the main thread.
    static func retire(_ player: VLCMediaPlayer) {
        let key = ObjectIdentifier(player)
        queue.async {
            retiring[key] = player
            player.stop()

            // Drain the main queue: every VLCKit event block enqueued before this
            // point runs and is disposed (dropping its retain of `player`) before
            // this hop executes — regardless of how busy the main thread is with,
            // e.g., a dismiss animation.
            DispatchQueue.main.async {
                queue.asyncAfter(deadline: .now() + graceInterval) {
                    // Final release happens HERE, on the teardown queue.
                    retiring.removeValue(forKey: key)
                }
            }
        }
    }
}
