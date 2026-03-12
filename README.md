# HA Menubar Volume

A native macOS menu bar app to control your RS232 amplifier volume via Home Assistant.

## How it works

Mac menu bar → HA REST API → `input_number` helper → your HA automation → RS232 serial → amp

## Features

- **Menu bar icon** with scroll-to-adjust volume
- **Custom slider** with smooth 80ms debounce (Combine-based)
- **Presets** — Off, Background, Listening, Loud (one-tap)
- **Mute toggle** that remembers your previous level
- **+/− step buttons** for fine 5% adjustments
- **Global hotkey** — ⌥⌘V toggles the popover from anywhere
- **Right-click menu** on the status icon for quick quit
- **Settings panel** — configure HA URL, token, and entity without editing code
- **Live connection indicator** with error display
- **Syncs initial volume** from HA on launch

## Setup

### 1. Home Assistant side

Create an `input_number` helper (Settings → Helpers → Add → Number, or YAML):

```yaml
input_number:
  amplifier_volume:
    name: Amplifier Volume
    min: 0
    max: 100
    step: 1
    icon: mdi:amplifier
```

Then an automation that watches the helper and sends the RS232 command:

```yaml
automation:
  - alias: "Amp volume changed"
    trigger:
      - platform: state
        entity_id: input_number.amplifier_volume
    action:
      - service: esphome.your_device_send_command
        data:
          command: "VOL{{ trigger.to_state.state | int }}"
```

### 2. Generate a Long-Lived Access Token

HA → Your Profile (bottom left) → Long-Lived Access Tokens → Create Token

### 3. Build in Xcode

1. New Project → macOS → App → SwiftUI
2. Delete the default `ContentView.swift`
3. Add all `.swift` files from this folder
4. Build with ⌘R — the app appears in the menu bar (no Dock icon)

### 4. Configure

Click the gear icon in the popover footer to enter your HA base URL, access token, and entity ID. Settings persist across launches.

## Files

| File | Purpose |
|---|---|
| `HAMenubarVolumeApp.swift` | App entry point, menu bar status item, popover, global hotkey, scroll-wheel handling |
| `HomeAssistantManager.swift` | REST API calls, reachability loop, volume fetch, persisted config via `@AppStorage` |
| `VolumeModel.swift` | Shared state, Combine debounce, presets, mute, volume stepping |
| `VolumePopoverView.swift` | SwiftUI popover UI — main view, presets bar, settings panel, custom slider |
