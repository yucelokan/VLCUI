# VLCUI

A [VLCKit](https://code.videolan.org/videolan/VLCKit) wrapper for SwiftUI.

## Requirements

The `vlc372` branch uses the VLCKit 3.7.2 binary distributed by
[`yucelokan/vlckit-spm`](https://github.com/yucelokan/vlckit-spm/tree/vlc372).

Add this branch with Swift Package Manager:

```swift
.package(url: "https://github.com/yucelokan/VLCUI.git", branch: "vlc372")
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
