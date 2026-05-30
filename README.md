# HA Menubar Volume

[![Build & Release](https://github.com/kevin-klemm/ha-menubar-volume/actions/workflows/build.yml/badge.svg)](https://github.com/kevin-klemm/ha-menubar-volume/actions/workflows/build.yml)
[![macOS](https://img.shields.io/badge/macOS-14.0%2B-blue)](https://github.com/kevin-klemm/ha-menubar-volume)
[![Swift](https://img.shields.io/badge/Swift-5.9-orange)](https://swift.org)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

A native macOS menu bar app to control volume via Home Assistant — backed by any `media_player` entity, including a `media_player` group that ties several systems together.

<p align="center">
  <img src="docs/screenshot.png" alt="Menu bar volume popover" width="296">
</p>

## How it works

Mac menu bar → HA REST API + WebSocket → `media_player.volume_set` + `media_player.volume_mute`

The app reads the `volume_level` and `is_volume_muted` attributes of one `media_player` entity and writes back via the standard `media_player` services. Point it at a single device or at an HA group that fans out to several.

## Features

- **Menu bar icon** with scroll-to-adjust volume
- **Custom slider** with smooth 80ms debounce (Combine-based)
- **Mute toggle** via `media_player.volume_mute`
- **+/− step buttons** for fine 5% adjustments (auto-unmutes)
- **Global hotkey** — ⌥⌘V toggles the popover from anywhere
- **Right-click menu** on the status icon — About, Check for Updates, Quit
- **Settings panel** — configure HA URL, token, and entity IDs without editing code
- **Launch at login** — toggle in Settings to start automatically after a reboot
- **Automatic updates** — built-in [Sparkle](https://sparkle-project.org) updater checks daily and on demand
- **Token stored in the Keychain** — not plaintext UserDefaults
- **Live connection indicator** with error display
- **Syncs state on launch** and stays in sync via WebSocket

## Setup

### 1. Home Assistant side

Pick any `media_player` entity that supports volume — a receiver, a speaker, a Sonos/AirPlay zone, etc.

To control several systems at once, make a **media player group** and point the app at that one entity. The easiest way is **Settings → Devices & Services → Helpers → Create Helper → Group → Media players**, or in YAML:

```yaml
media_player:
  - platform: group
    name: Whole House
    entities:
      - media_player.living_room
      - media_player.kitchen
      - media_player.office
```

Setting the volume on the group fans out to every member.

### 2. Generate a Long-Lived Access Token

HA → Your Profile (bottom left) → Long-Lived Access Tokens → Create Token

### 3. Download the app

Download the latest `ha-menubar-volume.dmg` from the [Releases page](https://github.com/kevin-klemm/ha-menubar-volume/releases), open it, and drag **Home Assistant Volume** onto the Applications shortcut.

> **First launch:** macOS may show a security warning since the app isn't notarized. Right-click the app → Open → Open to bypass it once. After that, the built-in updater installs new versions without the warning.

### 4. Configure

Click the gear icon in the popover footer to enter your HA base URL, access token, and entity IDs. Settings persist across launches (the token is kept in the macOS Keychain).

Flip **Launch at login** in the same Settings panel to have the app start automatically after a reboot — no need to launch it manually each time. Keep `Home Assistant Volume.app` in your Applications folder so the login item points at a stable location.

The app checks for updates automatically (daily) and via **Check for Updates…** in the right-click menu.
