# Voxport

A minimal macOS menu bar utility to adjust the **microphone (input) volume** with a sleek HUD that drops from the top center (over the notch area). It’s fast, scriptable, and stays out of your way.

## Features

- **Top-center HUD** (flat top, rounded bottom) with compact layout and percent readout.
- **Menu bar mic icon**  
  - Left-click: show HUD (auto-hides after ~5s).  
  - Right-click: context menu (Quit).
- **Controls the system *input* volume** using CoreAudio (master if present, per-channel fallback).
- **Auto-show on change**: whenever input volume changes (by app, scripts, or System Settings), the HUD pops for ~5s.
- **Scriptable without spawning a second instance** via Distributed Notifications.
- Optional **CLI flags** (will spawn another process; use notifications for long-running workflows).
- No Dock icon. Built in SwiftUI + AppKit.

## Screenshot

_Add a screenshot or short GIF here._

## Requirements

- macOS 12.0+ (Monterey) recommended  
- Xcode 15+ / Swift 5.9+  
- No microphone privacy permission required (we don’t capture audio; we adjust system volume via CoreAudio).

## Build & Run

1. Open the project in Xcode.
2. Select the **Voxport** scheme.
3. Build & run.

The app adds a **mic** icon to the menu bar. Left-click shows the HUD; right-click opens a menu with **Quit**.

## Usage

### From the menu bar
- **Left-click** the mic icon → HUD appears for ~5 seconds (auto-hide).
- **Right-click** → context menu with **Quit**.

### Keyboard / mouse
- Drag the slider to set input volume; the number on the right shows the current percentage.

### CLI (spawns a separate process)

> Prefer **Distributed Notifications** below for scripting; the CLI launches another process.

```bash
# Set input volume to an absolute percentage (0–100)
open -a Voxport --args --set-input-volume 37

# Change input volume relatively by delta in percent (±)
open -a Voxport --args --change-input-volume +5
open -a Voxport --args --change-input-volume -10
```

### Scriptable control (no second instance)

Post **Distributed Notifications** to the running app. These do not launch a new process and are preferred for automation.

**Set absolute percent**:

```bash
osascript -l JavaScript <<'JXA'
ObjC.import('Foundation')
$.NSDistributedNotificationCenter.defaultCenter
 .postNotificationNameObjectUserInfoDeliverImmediately(
    'Voxport.SetInputVolumePercent',
    null,
    {percent: 37},
    true
 )
JXA
```

**Change by delta**:

```bash
osascript -l JavaScript <<'JXA'
ObjC.import('Foundation')
$.NSDistributedNotificationCenter.defaultCenter
 .postNotificationNameObjectUserInfoDeliverImmediately(
    'Voxport.ChangeInputVolumeBy',
    null,
    {delta: -5},
    true
 )
JXA
```

The HUD will show for ~5 seconds in both cases.

## How it works (tech notes)

- **CoreAudio**: Queries default input device; sets `kAudioDevicePropertyVolumeScalar` on master element if available, otherwise per-channel (1…32).
- **Change observation**: Listens for default input device changes and input volume property changes; when triggered, refreshes UI and shows HUD.
- **UI**: SwiftUI for content; AppKit `NSPanel` for a non-activating, borderless, top-center HUD. Menubar via `NSStatusItem`.
- **Animation**: Top-anchored scale in/out via a wrapper `NSView` (`animView`) and Core Animation transform on its layer.

## Known issues / troubleshooting

- **First animation may pivot or “pop”** on some setups at app launch. Subsequent shows scale from the top center.
- **Early/late cut in the shrink/grow**: The app animates a dedicated wrapper layer to avoid mid-animation snaps; if you still see quirks, check for third‑party window managers and Reduce Motion settings.
- **Some audio devices ignore master volume**: The app falls back to per‑channel write; devices with unusual channel maps may read differently in vendor UI.

## Contributing

Issues and PRs welcome! If you’re tackling animation polish, please include:
- macOS version and display scale (Retina/non‑Retina, external monitor?)
- Repro steps and a short screen capture if possible.

## Roadmap / ideas

- Optional keyboard shortcuts (configurable hotkeys)
- Option to pin HUD while dragging (don’t auto‑hide)
- Presets or “snap to” steps (0/25/50/75/100)
- Optional sound feedback on change

## License — MIT

Copyright (c) 2025 Bastian Wölfle

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
