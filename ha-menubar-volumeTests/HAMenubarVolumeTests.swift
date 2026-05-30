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

    // MARK: parseVolumeLevel

    @Suite("parseVolumeLevel")
    struct ParseVolumeTests {
        @Test("0.6 → 60")
        func typical() {
            #expect(HomeAssistantManager.parseVolumeLevel(0.6) == 60)
        }

        @Test("0.0 → 0")
        func zero() {
            #expect(HomeAssistantManager.parseVolumeLevel(0.0) == 0)
        }

        @Test("1.0 → 100")
        func full() {
            #expect(HomeAssistantManager.parseVolumeLevel(1.0) == 100)
        }

        @Test("0.295 rounds to 30, not 29")
        func roundingUp() {
            #expect(HomeAssistantManager.parseVolumeLevel(0.295) == 30)
        }

        @Test("0.504 rounds to 50")
        func roundingDown() {
            #expect(HomeAssistantManager.parseVolumeLevel(0.504) == 50)
        }

        @Test("nil (attribute absent) returns nil")
        func absent() {
            #expect(HomeAssistantManager.parseVolumeLevel(nil) == nil)
        }

        @Test("non-numeric value returns nil")
        func nonNumeric() {
            #expect(HomeAssistantManager.parseVolumeLevel("unknown") == nil)
        }
    }

    // MARK: parseMuteFlag

    @Suite("parseMuteFlag")
    struct ParseMuteTests {
        @Test("true → true")
        func muteOn() {
            #expect(HomeAssistantManager.parseMuteFlag(true) == true)
        }

        @Test("false → false")
        func muteOff() {
            #expect(HomeAssistantManager.parseMuteFlag(false) == false)
        }

        @Test("nil (attribute absent) defaults to false")
        func absent() {
            #expect(HomeAssistantManager.parseMuteFlag(nil) == false)
        }

        @Test("unexpected type defaults to false")
        func unexpected() {
            #expect(HomeAssistantManager.parseMuteFlag("on") == false)
        }
    }

    // MARK: supportsVolumeSet

    @Suite("supportsVolumeSet")
    struct SupportsVolumeTests {
        @Test("VOLUME_SET bit present → true")
        func volumeSet() {
            #expect(HomeAssistantManager.supportsVolumeSet(4) == true)
        }

        @Test("typical media_player mask with volume → true")
        func combinedMask() {
            // PAUSE(1) | VOLUME_SET(4) | VOLUME_MUTE(8) = 13
            #expect(HomeAssistantManager.supportsVolumeSet(13) == true)
        }

        @Test("mask without VOLUME_SET → false")
        func noVolume() {
            // PAUSE(1) | PLAY(16384) — no volume bit
            #expect(HomeAssistantManager.supportsVolumeSet(16385) == false)
        }

        @Test("zero → false")
        func zero() {
            #expect(HomeAssistantManager.supportsVolumeSet(0) == false)
        }

        @Test("nil → false")
        func absent() {
            #expect(HomeAssistantManager.supportsVolumeSet(nil) == false)
        }
    }

    // MARK: displayName(forEntityID:)

    @Suite("displayName fallback")
    struct DisplayNameTests {
        @Test("single word entity")
        func single() {
            #expect(HomeAssistantManager.displayName(forEntityID: "media_player.master") == "Master")
        }

        @Test("multi-word slug is title-cased and spaced")
        func multiWord() {
            #expect(HomeAssistantManager.displayName(forEntityID: "media_player.living_room") == "Living Room")
        }

        @Test("no domain prefix")
        func noDomain() {
            #expect(HomeAssistantManager.displayName(forEntityID: "whole_house") == "Whole House")
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

