# Isle — Dynamic Island for the MacBook notch

The goal: everything the iPhone Dynamic Island does, translated to the Mac,
with the same motion language. Where iOS relies on something a Mac doesn't
have (Face ID, the silent switch, phone calls) the closest Mac equivalent is
used instead.

## 1. Presentations (the island's "shapes")

| iPhone | Isle | Notes |
|---|---|---|
| **Resting** — pill around the camera | **Idle** — black shape exactly over the notch, invisible | Grows a few points on hover, like a touch-down on iPhone |
| **Compact** — leading + trailing content around the camera | **Compact** — content to the left and right of the notch | Width adapts to content |
| **Minimal** — two activities: one attached, one detached bubble | **Split** — primary activity on the notch, second as a floating circle beside it | e.g. Timer + Music |
| **Expanded** — long-press to open the full activity | **Expanded** — hover (or click) to open | Tabs: Home, Timer, Shelf |
| **System alerts** — wide pill / banner | **HUD**, **Wide** and **Banner** alerts | Auto-dismiss; same-kind alerts update in place |

All shape changes are one continuous spring morph: the black body, its
concave "shoulders" at the top edge and its bottom corner radii all animate,
and content cross-fades with a blur, as on iOS.

## 2. Live Activities (persistent)

| Activity | Compact | Bubble | Expanded |
|---|---|---|---|
| **Now Playing** (any app: Music, Spotify, browsers, Podcasts…) | album art · live waveform tinted with the artwork's colour | spinning art | art, title, artist, waveform, scrubber you can drag, previous / play-pause / next, tap the art to open the source app |
| **Timer** | orange timer glyph · countdown | progress ring | presets, ring, pause / resume / cancel / +1 min |
| **Upcoming event** (Calendar) | calendar colour + "in 4m" | calendar glyph | day, date and next events |
| **Camera / microphone in use** | green camera / orange mic + dot | — | — |

Priority when several are live: Timer › Now Playing › Event › Privacy.

## 3. System alerts (transient)

| iPhone alert | Isle alert |
|---|---|
| Charging connected / disconnected | ⚡ Charging · 82 % with a battery glyph (wide) |
| Low battery | Banner at 20 % and 10 % |
| Low Power Mode | Wide alert when toggled |
| AirPods connected (with battery) | Any Bluetooth device: AirPods / Beats / keyboard / mouse icon, name, battery ring when the device reports it |
| Timer finished | Banner with Repeat / Stop, plays a sound |
| — | Caps Lock on / off |
| — | Event starting in 5 minutes |

Volume and brightness are left to macOS's own on-screen indicators, so
nothing shows twice.

## 4. Mac-only additions

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
