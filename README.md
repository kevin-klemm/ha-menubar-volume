# HA Menubar Volume

A native macOS menu bar app to control a volume level via Home Assistant — backed by an `input_number` helper for the level and a `switch` for mute.

## How it works

Mac menu bar → HA REST API + WebSocket → `input_number` (volume) + `switch` (mute)

The app reads and writes directly to your HA entities. What those entities actually control (a receiver, a speaker zone, a media player script, etc.) is up to your own automations.

## Features

- **Menu bar icon** with scroll-to-adjust volume
- **Custom slider** with smooth 80ms debounce (Combine-based)
- **Presets** — Background, Listening, Loud (one-tap)
- **Mute toggle** that remembers your previous level
- **+/− step buttons** for fine 5% adjustments
- **Global hotkey** — ⌥⌘V toggles the popover from anywhere
- **Right-click menu** on the status icon for quick quit
- **Settings panel** — configure HA URL, token, and entity IDs without editing code
- **Live connection indicator** with error display
- **Syncs state on launch** and stays in sync via WebSocket

## Setup

### 1. Home Assistant side

Create an `input_number` helper for volume (Settings → Helpers → Add → Number, or YAML):

```yaml
input_number:
  volume:
    name: Volume
    min: 0
    max: 1
    step: 0.01
    icon: mdi:volume-high
```

Create a `switch` helper for mute (Settings → Helpers → Add → Toggle, or YAML):

```yaml
input_boolean:
  mute:
    name: Mute
    icon: mdi:volume-off
```

### 2. Generate a Long-Lived Access Token

HA → Your Profile (bottom left) → Long-Lived Access Tokens → Create Token

### 3. Build in Xcode

1. Open `ha-menubar-volume.xcodeproj`
2. Build with ⌘R — the app appears in the menu bar (no Dock icon)

### 4. Configure

Click the gear icon in the popover footer to enter your HA base URL, access token, and entity IDs. Settings persist across launches.

## Files

| File | Purpose |
|---|---|
| `HAMenubarVolumeApp.swift` | App entry point, menu bar status item, popover, global hotkey, scroll-wheel handling |
| `HomeAssistantManager.swift` | REST API + WebSocket, reachability, state sync, persisted config via `@AppStorage` |
| `VolumeModel.swift` | Shared state, Combine debounce, presets, mute, volume stepping |
| `VolumePopoverView.swift` | SwiftUI popover UI — main view, presets bar, settings panel, custom slider |
