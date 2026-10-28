# VLCUI

A [VLCKit](https://code.videolan.org/videolan/VLCKit) wrapper for SwiftUI.

## Requirements

The `vlc372-new` branch uses the VLCKit 3.7.4 binary (libVLC 3.0.24)
distributed by [`yucelokan/vlckit-spm`](https://github.com/yucelokan/vlckit-spm/tree/vlc372).

Add this branch with Swift Package Manager:

```swift
.package(url: "https://github.com/yucelokan/VLCUI.git", branch: "vlc372-new")
```

## Usage

For startup investigations, opt in with `Configuration(...,
startupDiagnosticsEnabled: true)`. This installs an allowlisted shared-library
logger: connection phases, HTTP status codes, module-selection milestones and
clock/audio errors only. It never forwards raw messages, URLs, hosts, credentials
or headers. Each startup window is capped at 30 seconds / 128 events, with at most
three occurrences per emitter/event. It makes no probe requests and changes no
playback/retry decisions. `epoch` identifies the diagnostic window, **not** a
libVLC input's ownership: old and current players can emit in the same window.
Opt-in diagnostics do not sanitize any separate raw logger installed by a client.

To deliver the same safe events to a host-owned logger, install a process-wide
observer before creating a player:

```swift
VLCPlaybackDiagnostics.install { event in
    // Called on a bounded utility queue, never libVLC's worker. The host owns
    // serialization, persistence and any application-specific log schema.
    if event.scope == .sharedLibrary {
        // No player ownership is available; startupWindow is only a time window.
        recordSharedDiagnostic(kind: event.kind, httpStatus: event.httpStatusCode)
    } else {
        recordPlayerDiagnostic(kind: event.kind, playerID: event.playerID)
    }
}
// Remove the observer when no longer needed.
VLCPlaybackDiagnostics.install(nil)
```

The immutable projection exposes only closed event kinds, validated HTTP status
codes, random concrete-player IDs and timing/window numbers. Shared-library
events never carry a player ID. Per-player terminal errors are emitted once;
libVLC does not expose their underlying cause. Host delivery is capped at 256
pending events, and shared events retain the startup time/repeat/total budgets.
Already queued events retain their original receiver and identity when a player
or observer is replaced. Installing an observer does not enable console logging
or opt clients into the recovery snapshot below.

Single-player clients can also enable `startupNetworkObservationEnabled` and read
`Proxy.startupNetworkActivitySnapshot`. The snapshot contains only request/response
counts, a validated status code and the age/class of an unanswered request. It
does not print or retain URLs, hosts, headers or raw messages, and performs no
network request. The client owns any timeout or recovery decision.

Run `ruby scripts/check_startup_diagnostics.rb` for isolated privacy/budget checks.
The optional `--with-vlckit-fixture` uses an existing cached macOS framework and a
loopback-only HTTP 503 server to verify the real callback without building an app
or connecting to a media provider.

```swift
struct ContentView: View {
	var body: some View {
		VLCVideoPlayer(url: /* video url */)
	}
}
```

## Example

An example project is provided to show basic functionality of VLCUI. Download the
VLCKit 3.7.2 frameworks with the provided **Cartfile**:

```shell
carthage update --use-xcframeworks
```
