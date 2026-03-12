import Foundation

import Testing
@testable import ha_menubar_volume

// MARK: - HomeAssistantManager Tests

@Suite("HomeAssistantManager")
struct HomeAssistantManagerTests {

    // MARK: wsURL

    @Suite("wsURL")
    struct WSURLTests {
        @Test("http converts to ws")
        func httpToWS() {
            let url = HomeAssistantManager.wsURL(from: "http://homeassistant.local:8123")
            #expect(url == URL(string: "ws://homeassistant.local:8123/api/websocket"))
        }

        @Test("https converts to wss")
        func httpsToWSS() {
            let url = HomeAssistantManager.wsURL(from: "https://home.example.com")
            #expect(url == URL(string: "wss://home.example.com/api/websocket"))
        }

        @Test("trailing slash is stripped")
        func trailingSlash() {
            let url = HomeAssistantManager.wsURL(from: "http://homeassistant.local:8123/")
            #expect(url == URL(string: "ws://homeassistant.local:8123/api/websocket"))
        }

        @Test("empty string returns nil")
        func emptyString() {
            #expect(HomeAssistantManager.wsURL(from: "") == nil)
        }

        @Test("path is appended to existing port")
        func withPort() {
            let url = HomeAssistantManager.wsURL(from: "http://192.168.1.10:8123")
            #expect(url == URL(string: "ws://192.168.1.10:8123/api/websocket"))
        }
    }

    // MARK: parseVolumeState

    @Suite("parseVolumeState")
    struct ParseVolumeTests {
        @Test("0.6 → 60")
        func typical() {
            #expect(HomeAssistantManager.parseVolumeState("0.6") == 60)
        }

        @Test("0.0 → 0")
        func zero() {
            #expect(HomeAssistantManager.parseVolumeState("0.0") == 0)
        }

        @Test("1.0 → 100")
        func full() {
            #expect(HomeAssistantManager.parseVolumeState("1.0") == 100)
        }

        @Test("0.295 rounds to 30, not 29")
        func roundingUp() {
            #expect(HomeAssistantManager.parseVolumeState("0.295") == 30)
        }

        @Test("0.504 rounds to 50")
        func roundingDown() {
            #expect(HomeAssistantManager.parseVolumeState("0.504") == 50)
        }

        @Test("unavailable returns nil")
        func unavailable() {
            #expect(HomeAssistantManager.parseVolumeState("unavailable") == nil)
        }

        @Test("empty string returns nil")
        func empty() {
            #expect(HomeAssistantManager.parseVolumeState("") == nil)
        }

        @Test("non-numeric string returns nil")
        func nonNumeric() {
            #expect(HomeAssistantManager.parseVolumeState("unknown") == nil)
        }
    }

    // MARK: parseMuteState

    @Suite("parseMuteState")
    struct ParseMuteTests {
        @Test("on → true")
        func muteOn() {
            #expect(HomeAssistantManager.parseMuteState("on") == true)
        }

        @Test("off → false")
        func muteOff() {
            #expect(HomeAssistantManager.parseMuteState("off") == false)
        }

        @Test("unexpected value defaults to false")
        func unexpected() {
            #expect(HomeAssistantManager.parseMuteState("unknown") == false)
        }

        @Test("unavailable defaults to false")
        func unavailable() {
            #expect(HomeAssistantManager.parseMuteState("unavailable") == false)
        }
    }
}

// MARK: - VolumeModel Tests

@Suite("VolumeModel")
struct VolumeModelTests {

    // MARK: clamp

    @Suite("clamp")
    struct ClampTests {
        @Test("negative clamps to 0")
        func belowZero() {
            #expect(VolumeModel.clamp(-1) == 0)
        }

        @Test("above 100 clamps to 100")
        func above100() {
            #expect(VolumeModel.clamp(101) == 100)
        }

        @Test("value within range is unchanged")
        func inRange() {
            #expect(VolumeModel.clamp(50) == 50)
        }

        @Test("boundary 0 is valid")
        func boundaryZero() {
            #expect(VolumeModel.clamp(0) == 0)
        }

        @Test("boundary 100 is valid")
        func boundary100() {
            #expect(VolumeModel.clamp(100) == 100)
        }

        @Test("large negative clamps to 0")
        func largeNegative() {
            #expect(VolumeModel.clamp(-999) == 0)
        }

        @Test("large positive clamps to 100")
        func largePositive() {
            #expect(VolumeModel.clamp(999) == 100)
        }
    }

    // MARK: activePreset

    @Suite("activePreset")
    struct ActivePresetTests {
        private let presets = VolumeModel.defaultPresets

        @Test("exact match — Background")
        func exactBackground() {
            #expect(VolumeModel.activePreset(for: 50, in: presets) == "Background")
        }

        @Test("exact match — Listening")
        func exactListening() {
            #expect(VolumeModel.activePreset(for: 75, in: presets) == "Listening")
        }

        @Test("exact match — Loud")
        func exactLoud() {
            #expect(VolumeModel.activePreset(for: 100, in: presets) == "Loud")
        }

        @Test("within threshold above preset matches")
        func nearAbove() {
            #expect(VolumeModel.activePreset(for: 51.5, in: presets) == "Background")
        }

        @Test("within threshold below preset matches")
        func nearBelow() {
            #expect(VolumeModel.activePreset(for: 48.5, in: presets) == "Background")
        }

        @Test("just outside threshold returns nil")
        func outsideThreshold() {
            #expect(VolumeModel.activePreset(for: 52.1, in: presets) == nil)
            #expect(VolumeModel.activePreset(for: 47.9, in: presets) == nil)
        }

        @Test("midway between presets returns nil")
        func midway() {
            #expect(VolumeModel.activePreset(for: 62, in: presets) == nil)
        }

        @Test("empty preset list returns nil")
        func emptyPresets() {
            #expect(VolumeModel.activePreset(for: 50, in: []) == nil)
        }
    }
}

