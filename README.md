# HA Menubar Volume

[![Build & Release](https://github.com/kklemm/ha-menubar-volume/actions/workflows/build.yml/badge.svg)](https://github.com/kklemm/ha-menubar-volume/actions/workflows/build.yml)
[![macOS](https://img.shields.io/badge/macOS-14.0%2B-blue)](https://github.com/kklemm/ha-menubar-volume)
[![Swift](https://img.shields.io/badge/Swift-5.9-orange)](https://swift.org)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

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

### 3. Download the app

Download the latest `ha-menubar-volume.zip` from the [Releases page](https://github.com/kklemm/ha-menubar-volume/releases), unzip it, and move `ha-menubar-volume.app` to your Applications folder.

> **First launch:** macOS may show a security warning since the app isn't notarized. Right-click the app → Open → Open to bypass it once.

### 4. Configure

Click the gear icon in the popover footer to enter your HA base URL, access token, and entity IDs. Settings persist across launches.
