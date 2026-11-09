# VLC start benchmark: VLCKit 3.7.4 against 4.0.0a18

How long VLC takes to start a real provider's live channel, movie and episode, and to switch channels, with VLCKit
3.7.4 and with VLCKit 4.0.0a18, on the same simulator, streams and options. It feeds the continue-or-drop proposal on
VLCKit 4 (Paperclip WUW-144). The harness lives on `vlckit-4.0` and changes nothing outside `Benchmark/`.

## Why a separate host

The app cannot measure this directly. Its VLCUI adapter uses ten fork APIs that `vlckit-4.0` lacks, and the
measurement must not change the app's package pins. So one small host app builds unchanged against both VLCUI
revisions and uses only the API they share:
- `VLCVideoPlayer(configuration:)`, `.proxy(_:)`, `.onStateUpdated(_:)`, `.onSecondsUpdated(_:)`;
- `VLCVideoPlayer.Proxy.playNewMedia(_:)`;
- the shared `VLCVideoPlayer.Configuration` initializer.

| Side | VLCUI | vlckit-spm | libVLC (version, changeset) |
| --- | --- | --- | --- |
| 3.7.4 | `bd16de8c` (`vlc372-new`, the app's 1.2.5 pin) | `vlc372` @ `0fa85a10` | 3.0.24, `3.0.24-42-gcdceca9c6f` |
| 4.0.0a18 | `27ea0f20` (`vlckit-4.0`) | `vlckit-4.0` @ `772ddbea` | 4.0.0-dev, `4.0.0-dev-35511-ga9e2f402ca` |

## What is measured

| Number | From | To |
| --- | --- | --- |
| Start (L1, M1, E1) | A new player view is requested | First motion |
| Next (L1 → L2), Previous (L2 → L1) | `Proxy.playNewMedia` on the running player, as the app's channel switch | First motion of the new channel |
| Clock start | the same request | first motion minus the media time reached by then: when the playback clock started |
| `.playing` | the same request | VLCUI's first `.playing` state |
| Failure | an attempt with `.error` before first motion, no motion within 20 s, or no result from the app | |
| Stall | the engine's buffering state (or an error) during the 5 s hold after first motion | |
| Memory | `phys_footprint` at the end of the hold (steady) and its peak over the attempt (100 ms samples) | |

- **First motion** is the app's own rule (`NAVLCSessionEngineAdapter.publish`): the first `onSecondsUpdated` callback
  whose time is later than the previous callback's. Callbacks of an earlier player or another media (checked through
  `PlaybackInformation.startConfiguration.url`) are never counted.
- **One clock:** Swift's `ContinuousClock`, read in the callbacks on the main thread. The waiting loop only notices the
  result; it never sets a time.
- **Two comparable numbers: first motion and clock start.**
  - First motion is the app's clock (WUW-37), but it depends on how often a revision reports the playhead. VLCKit 4
    reports it once a second (`timeChangeUpdateInterval` defaults to 1.0 s), 3.7.4 about every 300 ms (and VLCUI 3.7.4
    swallows the first callback). So on 4.0 first motion lands up to ~2 s after the clock really started. Each sample
    records the cadence (`tick_interval_p50_ms`).
  - Clock start does not depend on that cadence: at first motion the media time says how long the clock has run. It is
    kept only when plausible (media time at or above zero and not beyond first motion). In the correctness rounds it
    agreed within a few milliseconds whichever callback it was computed from.
  - On 4.0, the first playhead value of a live stream is the stream's raw timestamp (hours), then the time restarts
    near zero. The app's rule (a later callback with a larger time) skips it; it is visible in `first_tick_media_ms`.
- **`.playing` is recorded, not compared.** On 3.7.4 VLCUI reports it once the playhead has moved 200 ms; on 4.0 it
  also passes libVLC's own playing state through, before any frame.
- **States are named the engine's way.** VLCUI's `State` keeps VLCKit 3's order and the 4.0 revision wraps VLCKit 4's
  state by raw value, but VLCKit 4 numbers its states differently, so VLCUI 4.0 reports buffering as `.ended` and
  opening as `.buffering`. The host maps each raw value back to the engine's name (`App/Engine.swift`
  `EngineState`) and counts stalls and errors from that; VLCUI's own names are kept in `vlcui_states`.
- **The app's default options** (`NAPlayerViewModel.buildCommonVLCOptions` with `NAPlayerSettings.default`, see
  `App/Engine.swift`): `network-caching` 1500, `adaptive-logic` highest, `avcodec-hw` any, `clock-jitter` 0,
  `clock-synchro` 0, freetype subtitles (size 20, Verdana, white, UTF-8), no deinterlace, no aspect ratio. The
  configuration matches the shared part of the app's: rate 1, subtitle size, font and colour, `.auto` tracks.
  - Not used, because 4.0 lacks them: the fork's `initialVolume: 0`, `serializesInputHandover` and the startup network
    observation. The host therefore starts with the volume at its default on both sides.
- **Teardown** is each revision's own: removing the view retires the player (3.7.4: off the main thread in
  `dismantleUIView`; 4.0: `stop()` in `deinit`). A 2 s settle keeps it out of the next start.

## A round

One launch of one side's app plays one round: L1 start, Next to L2, Previous to L1, M1 start, E1 start. Each step that
reaches first motion is held for 5 s. Starting the app creates the shared `VLCLibrary` (it reports its version), then
waits 2 s, so libVLC's own start-up is outside every time.

- **Alternation:** both apps are installed side by side (their own product names and bundle ids). Each platform runs one
  labelled warm-up round per side, then the measured rounds as A B B A A B B A … (3.7.4, 4.0.0a18). Drift over the run
  (provider, CDN, the Mac's temperature, caches) lands on both sides. Warm-ups stay in the raw CSV and never count.
- **Defaults:** 20 measured rounds per side and platform: 20 starts of L1, M1 and E1 and 20 of each switch.
- **Streams:** the set S1 from the benchmark matrix (Paperclip WUW-37, `benchmark-matrix`). The private map
  `~/.private_keys/wuwtv/player-benchmark-streams.json` (0600) and its profile give the addresses, built as the app
  builds Xtream addresses (`/live/…/<id>.ts`, `/movie/…/<id>.<ext>`, `/series/…/<episode>.<ext>`). The profile is read
  with wuwtv's `release_tests.load_playlist_profile`, imported by path from the wuwtv task worktree.

## Privacy

- The addresses reach only the plan file in the app's data container (`Documents/plan.json`, 0600). The app deletes
  it once read; the driver deletes it after each launch and removes both apps (and the device) at the end.
- Results, printed lines and records hold aliases, states and numbers only. Every record is checked before it is
  written: one that holds an address, the host, the account or a stream address is refused.
- No screenshot or recording is taken: the screen shows the provider's content.

## Containment

- `build` takes an ordinary agent build slot through wuwtv's `scripts/agent_build.sh`, with a generic destination. It
  never touches a simulator, and refuses to run inside `locked`.
- `run` refuses to start outside `scripts/agent_build.sh locked`. It uses its own simulators, `WUWTV Benchmark VLC
  iPhone` and `WUWTV Benchmark VLC Apple TV`, which copy the device type and runtime of `WUWTV Release iPhone` /
  `WUWTV Release Apple TV` (iPhone 17, iOS 27.0; Apple TV 4K 3rd generation, tvOS 27.0). It creates them inside the
  lock, removes any left over first, and deletes them at the end. Every app removal and device deletion checks the
  device name first; only the benchmark's own bundle ids are ever removed.
- SIGTERM (the stall watchdog's stop) becomes `SystemExit`, so the cleanup runs.
- **Start condition** for timed runs, recorded with the results: no other holder in the agent queue, and the Mac's CPU
  under 20 % over 30 s with the benchmark device booted. `--start-by` refuses a late start; `--deadline` launches no
  round that could end after it.
- **CPU:** the run samples the Mac's CPU every 15 s itself (`environment.json` `cpu_during_run`: peak, mean, seconds
  over 70 % and the series). The `locked` exit line prints the same for the whole lock. In the correctness rounds the
  simulator boot reached 86–99 % for about 40 s; playback stayed at 14–32 %.

## Pinning

VLCUI pulls vlckit-spm by branch, so pinning VLCUI alone would let VLCKit float. For each side `build` writes into a
temporary copy of the project both the VLCUI revision and a `Package.resolved` that pins VLCUI and vlckit-spm, builds
with `-onlyUsePackageVersionsFromResolvedFile`, and then checks the resolved file and the package checkouts against the
side's revisions. A mismatch discards the app. Each app is then copied out of DerivedData into
`~/Library/Developer/WUWTV-vlc-start-benchmark/builds/apps/<side>-<platform>-<kind>/`: both sides build the same target,
so Xcode removes one side's app from `Build/Products` as a stale output when the other side builds. The build record
(`builds/<side>-<platform>-<kind>.json`) keeps the resolved file, the executable's SHA-256 and the embedded frameworks. `run` refuses an app that changed since its build record, and a side whose app reports another
libVLC version or changeset.

## Commands

```sh
W=<wuwtv task worktree>
export WUWTV_AGENT_DERIVED_DATA=~/Library/Developer/Xcode/DerivedData/WUWTV-agent-wt-<this VLCUI worktree folder>
B=Benchmark/scripts/vlc_start_benchmark.py

python3 $B --wuwtv $W build --platform ios        # Release simulator apps, both sides (tvOS: see Limits)
python3 $B --wuwtv $W build --device              # Release device apps (unsigned), for the size
python3 $B sizes                                  # bundle, zipped and VLCKit binary size per side, and the delta

# One correctness round per side and platform (numbers thrown away):
$W/scripts/agent_run.sh -- $W/scripts/agent_build.sh locked python3 $B --wuwtv $W run --correctness --platform ios

# The timed run, in its agreed window, in the background:
$W/scripts/agent_run.sh --done 'VLC start benchmark: (finished|FAILED)' -- \
  $W/scripts/agent_build.sh locked python3 $B --wuwtv $W run --platform ios --start-by <UTC> --deadline <UTC>

python3 $B report ~/Library/Developer/WUWTV-vlc-start-benchmark/<run> --csv samples.csv
```

- **Results** go to `~/Library/Developer/WUWTV-vlc-start-benchmark/<time>-<label>/` (0700): `environment.json` (Xcode,
  SDKs, macOS, host, the builds' pins and frameworks, devices, the start condition, CPU, the schedule, the libraries
  the apps reported), `samples.jsonl` and `samples.csv` (one row per attempt), `summary.json`.
- **Report:** per platform, side and step: n, p50, p90 (nearest rank), min and max of first motion; failures (errors,
  timeouts, no result); stalls; `.playing` p50; steady and peak memory. Then 4.0.0a18 against 3.7.4: Δp50 and Δp90.
- **Tests:** `python3 -m unittest Benchmark/scripts/test_vlc_start_benchmark.py`.

## Limits

- **tvOS: the 4.0.0a18 side does not build.** VLCUI `27ea0f20` uses VLCKit's Chromecast renderer and transcoder
  (`VLCRendererDiscoverer`, `VLCRendererItem`, `VLCTranscoder`, `VLCMediaPlayer.setRendererItem`) in `Proxy.swift`
  without a platform check, and the tvOS slices of the 4.0.0a18 xcframework ship no such headers (the iOS and macOS
  slices do). So only iOS compares the two sides. A tvOS comparison needs a VLCUI change on `vlckit-4.0` first, outside
  this folder. The 3.7.4 tvOS app builds.

- Simulator numbers: the engines run on the Mac's CPU, and `phys_footprint` is the simulator process's. They compare the
  two VLCKit versions with each other on the same Mac, never with a device or another app.
- The comparison is VLCUI plus VLCKit as each revision ships, not libVLC alone: the two VLCUI revisions also differ in
  how they deliver callbacks and tear players down.
