# Isle

The iPhone Dynamic Island, for the MacBook notch. Native Swift + SwiftUI,
Apple Silicon, macOS 14 or later. See [FEATURES.md](FEATURES.md) for the full
feature list.

## Build & run

```bash
./scripts/build.sh            # → build/Isle.app
./scripts/build.sh --install  # copy to /Applications and launch
```

Requires Xcode (or the Command Line Tools) with Swift 6.

## First launch

Isle is a menu-bar-less accessory app: look at your notch. macOS will ask for:

* **Calendar** — next event and five-minute reminders
* **Bluetooth** — AirPods / device connect alerts
* **Automation (Music / Spotify)** — only if the system-wide Now Playing
  helper can't see your player

Builds are ad-hoc signed, so macOS may ask again after a rebuild.

## Architecture

```
Sources/IsleKit/            platform-independent core, unit tested
  IslandEngine              state machine: expanded › alert › live activities › idle,
                            alert queueing/coalescing, hover / click / file-drag logic
  IslandLayout              every size derived from the notch's real geometry
  SwipeInterpreter          trackpad deltas → one gesture per swipe
Sources/Isle/
  App/                      composition root (IsleContainer), preferences, settings, menu bar
  Platform/                 click-through NSPanel, pointer / drag / swipe input, screen location
  Island/                   the morphing island: root, compact, alert and expanded content
  DesignSystem/             motion and colour tokens, notch shape, shared components
  Features/<Name>/          one folder per feature: @Observable model + system integration + views
  Snapshots/                offscreen renderer for design review
Tests/IsleKitTests/         Swift Testing suite for the engine, layout and gestures
```

Swift 6 language mode with complete concurrency checking. Models are
`@Observable` and main-actor isolated; slow work (Apple Events, artwork
colour extraction, device queries, bridge decoding) runs off the main actor.
Timing uses Swift concurrency tasks, so the engine is testable with an
injected sleep.

```bash
swift test                                   # IsleKit engine tests + app feature tests
.build/debug/Isle --snapshots ./snapshots    # render every island state to PNG
```

## Release

```bash
./scripts/build.sh --release                 # tests → build → sign → build/Isle-<version>.zip
```

* **Version** comes from the latest git tag (`v1.2.0` → 1.2.0); the build number is the commit count.
* **Signing:** set `SIGN_IDENTITY="Developer ID Application: …"` for a hardened-runtime
  signature with `Resources/Isle.entitlements`. Without it, builds are ad-hoc signed.
* **Notarization:** also set `NOTARY_PROFILE` (saved with `xcrun notarytool store-credentials`)
  and the zip is notarized and stapled.
* **CI** (`.github/workflows/ci.yml`) runs tests, builds the app, and uploads the
  app and the rendered island states on every push and pull request.

## Diagnostics

Lifecycle events and errors (never per-track data) go to the unified log
(subsystem `com.avhiejeet.Isle`) and to `~/Library/Logs/Isle.log`, which rotates at 512 KB.

## Energy

Isle is event-driven: no global mouse monitoring, no polling for brightness,
camera/microphone, calendar or players, and the waveform animates in the window
server. At rest it measures 0.0% CPU and an energy impact of 0.0. Decorative
motion holds still under Low Power Mode and Reduce Motion.

## How Now Playing works

macOS 15.4 restricted MediaRemote (the system Now Playing service) to
Apple-signed processes. Isle loads a small bridge library into the Apple-signed
`/usr/bin/perl`, which streams track info as JSON and accepts play/pause, skip
and seek commands. If the bridge can't see a player, Isle falls back to
AppleScript for Music and Spotify. You can turn the bridge off in
Settings → Live Activities → "Include browsers and all other apps".
