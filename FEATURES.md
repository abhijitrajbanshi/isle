# Isle — the notch that does your waiting for you

Isle is designed for the Mac's notch, not copied from the iPhone. The island
grows straight down out of the bezel; its body is always opaque black and
only content takes colour (one thing at a time); it's as tall as what's in
it; motion is critically damped and interruptible; and with nothing to say it
is simply the notch.

## 1. Presentations (the island's "shapes")

| iPhone | Isle | Notes |
|---|---|---|
| **Resting** — pill around the camera | **Idle** — black shape exactly over the notch, invisible | Grows a few points on hover, like a touch-down on iPhone |
| **Compact** — leading + trailing content around the camera | **Compact** — content to the left and right of the notch | Width adapts to content |
| **Minimal** — two activities: one attached, one detached bubble | **Split** — primary activity on the notch, second as a floating circle beside it | e.g. Timer + Music |
| **Expanded** — long-press to open the full activity | **Open** — hover (or click) to open | A stack: the most urgent activity at full size, everything else running as rows beneath; click a row to bring it up. Sized to its content |
| **System alerts** — wide pill / banner | **HUD**, **Wide** and **Banner** alerts | Auto-dismiss; same-kind alerts update in place |

All shape changes are one continuous spring morph: the black body, its
concave "shoulders" at the top edge and its bottom corner radii all animate,
and content cross-fades with a blur, as on iOS.

## 2. Live Activities (persistent)

| Activity | Compact | Open |
|---|---|---|
| **Claude Code** | project · "4m" working, amber **Allow?** when it needs you, green "Your turn" | what it's doing; a permission request takes over with the exact command or file, **Allow** / **Deny** / Answer in Claude. "Done" banner when it stops |
| **Tasks** (`isle run`, `isle progress`) | progress ring · percentage | title, detail, progress bar; ✓ or ✗ banner with the time it took |


| Activity | Compact | Bubble | Expanded |
|---|---|---|---|
| **Now Playing** (any app: Music, Spotify, browsers, Podcasts…) | album art · live waveform tinted with the artwork's colour | spinning art | art, title, artist, waveform, scrubber you can drag, previous / play-pause / next, tap the art to open the source app |
| **Timer** | orange timer glyph · countdown | progress ring | presets, ring, pause / resume / cancel / +1 min |
| **Upcoming event** (Calendar) | calendar colour + "in 4m"; a **Join** button for calls about to start | calendar glyph | the next call with **Join** and mic mute, or the rest of today |
| **Camera / microphone in use** | green camera / orange mic + dot; red mic-slash when you're muted | — | — |

Priority when several are live: Agent › Timer › Now Playing › Task › Event › Privacy.

## 3. System alerts (transient)

| iPhone alert | Isle alert |
|---|---|
| Charging connected / disconnected | ⚡ Charging · 82 % with a battery glyph (wide) |
| Low battery | Banner at 20 % and 10 % |
| Low Power Mode | Wide alert when toggled |
| AirPods connected (with battery) | Any Bluetooth device: AirPods / Beats / keyboard / mouse icon, name, battery ring when the device reports it |
| Timer finished | Banner with Repeat / Stop, plays a sound |
| — | Caps Lock on / off |
| — | Event starting in 5 minutes, with **Join** for Zoom, Meet, Teams, Webex, FaceTime, Slack and Whereby calls |

Volume and brightness are left to macOS's own on-screen indicators, so
nothing shows twice.

## 4. Mac-only additions

* **Meetings** — finds the call link in an event's URL, location or notes;
  Join from the notch, the five-minute banner or the expanded island.
* **Microphone mute** — one click mutes the Mac's microphone for every app
  (Zoom, Teams, the browser), with the state shown in the notch.
* **Sound output** — switch between AirPods, speakers and displays from the
  island instead of Control Centre.
* **Keep awake** — stop the Mac and display sleeping for 30 minutes, 1 or 2
  hours, or until turned off (like `caffeinate`), from the right-click menu.
* **Timer** presets from the right-click menu.
* **Auto-updates** — checks GitHub once a day and installs signed updates (Sparkle); “Check for Updates…” in the menu bar and Settings.

* **File Shelf** — drag a file onto the notch and the island opens a shelf.
  Files stay there; drag them out, open them, show them in Finder or send them
  over **AirDrop**.
* Hover-to-expand with an adjustable delay, or click-to-expand.
* Trackpad haptic tick when the island opens.
* Works on Macs **without** a notch: the island hangs from the menu bar as a
  floating pill and hides when idle.
* Follows display changes; runs on every Space and over full-screen apps.
* Settings window in the System Settings style; launch at login; optional
  menu bar icon.

## 5. Interaction model

* Hover → expand (default 0.15 s), move away → collapse.
* Click the compact island → expand.
* Click the album art → open the playing app.
* Right-click → Settings / Quit.
* Drag a file towards the notch → Shelf opens and accepts the drop.

## 6. What isn't possible on macOS

* **Focus mode changes** — no public API without Full Disk Access.
* **Other apps' notifications** — macOS doesn't expose them.
* **AirPods battery** is read from a private property. It is shown when
  macOS provides it and left out otherwise.
