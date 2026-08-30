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
