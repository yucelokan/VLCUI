import SwiftUI
import VLCUI

/// The start benchmark host (Benchmark/README.md). It builds unchanged against both VLCUI revisions and uses only the
/// API they share. Opened without a plan from the driver, it does nothing.
@main
struct BenchmarkApp: App {

    @StateObject
    private var runner = BenchmarkRunner()

    var body: some Scene {
        WindowGroup {
            BenchmarkView(runner: runner)
                .task { await runner.run() }
        }
    }
}

struct BenchmarkView: View {

    @ObservedObject
    var runner: BenchmarkRunner

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black
                .ignoresSafeArea()
            if let slot = runner.slot {
                // One view per start: a start creates a fresh player, as the app's player cover does. Next and
                // Previous reuse it through `Proxy.playNewMedia`, as the app's channel switch does.
                VLCVideoPlayer(configuration: slot.configuration)
                    .proxy(slot.proxy)
                    .onStateUpdated { state, info in
                        MainActor.assumeIsolated { runner.stateUpdated(state, info, slot: slot.id) }
                    }
                    .onSecondsUpdated { seconds, info in
                        MainActor.assumeIsolated { runner.secondsUpdated(seconds, info, slot: slot.id) }
                    }
                    .id(slot.id)
                    .ignoresSafeArea()
            }
            // Aliases and states only: never a stream name or address.
            Text(runner.status)
                .font(.caption.monospaced())
                .foregroundStyle(.white)
                .padding(8)
                .background(.black.opacity(0.6))
                .padding()
        }
    }
}
