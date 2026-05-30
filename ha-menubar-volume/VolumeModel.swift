import SwiftUI
import Combine

/// Central volume state with debounced HA updates, presets, and mute support.
class VolumeModel: ObservableObject {
    static let shared = VolumeModel()

    // MARK: - Published State

    @Published var volume: Double = 35
    @Published var isMuted: Bool = false
    @Published var activePreset: String?
    @Published var hasSyncedInitialVolume: Bool = false

    // MARK: - Presets

    struct Preset: Identifiable {
        let id = UUID()
        let name: String
        let icon: String
        let volume: Double
    }

    static let defaultPresets: [Preset] = [
        Preset(name: "Background", icon: "speaker.wave.1",   volume: 50),
        Preset(name: "Listening",  icon: "speaker.wave.2",   volume: 75),
        Preset(name: "Loud",       icon: "speaker.wave.3",   volume: 100),
    ]

    let presets: [Preset] = defaultPresets

    // MARK: - Pure Helpers (internal for testability)

    /// Clamp a raw volume value to the valid 0–100 range.
    static func clamp(_ volume: Double) -> Double {
        max(0, min(100, volume))
    }

    /// Return the name of the first preset within 2 units of the given volume, or nil.
    static func activePreset(for volume: Double, in presets: [Preset]) -> String? {
        presets.first(where: { abs($0.volume - volume) < 2 })?.name
    }

    // MARK: - Private

    private let ha = HomeAssistantManager.shared
    private var volumeSubject = PassthroughSubject<Double, Never>()
    private var cancellables = Set<AnyCancellable>()

    /// Tracks whether the most recent volume change was initiated locally (by this app).
    /// Used to prevent WebSocket echoes from fighting the slider.
    private var isLocalChange = false
    private var localChangeResetTask: Task<Void, Never>?

    init() {
        // Debounce volume changes at 80ms using Combine
        volumeSubject
            .debounce(for: .milliseconds(80), scheduler: RunLoop.main)
            .sink { [weak self] vol in
                guard let self, !self.isMuted else { return }
                self.ha.setVolume(Int(vol))
            }
            .store(in: &cancellables)

        // Observe remote volume changes pushed via WebSocket
        ha.$currentRemoteVolume
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] remoteVol in
                guard let self else { return }
                // Skip if this change originated locally (avoids slider jitter)
                guard !self.isLocalChange else { return }
                let newVol = Double(remoteVol)
                // Only update if meaningfully different (avoids rounding loops)
                if abs(self.volume - newVol) >= 1.0 {
                    self.volume = newVol
                    self.updateActivePreset()
                }
            }
            .store(in: &cancellables)

        // Observe remote mute changes pushed via WebSocket
        ha.$currentRemoteMute
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] remoteMuted in
                guard let self else { return }
                guard !self.isLocalChange else { return }
                if self.isMuted != remoteMuted {
                    self.isMuted = remoteMuted
                }
            }
            .store(in: &cancellables)

        // Pull authoritative state from HA on launch
        syncFromRemote()
    }

    /// Mark that changes are originating locally; auto-resets after a delay.
    private func markLocalChange() {
        isLocalChange = true
        localChangeResetTask?.cancel()
        localChangeResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            guard !Task.isCancelled else { return }
            self.isLocalChange = false
        }
    }

    // MARK: - Actions

    func setVolume(_ newVolume: Double) {
        let clamped = Self.clamp(newVolume)
        // Adjusting the volume implicitly unmutes — otherwise the debounced HA
        // write (which is suppressed while muted) would silently drop the change.
        if isMuted {
            isMuted = false
            ha.setMute(false)
        }
        volume = clamped
        activePreset = nil
        updateActivePreset()
        markLocalChange()
        volumeSubject.send(clamped)
    }

    func stepVolume(by delta: Double) {
        setVolume(volume + delta)
    }

    func applyPreset(_ preset: Preset) {
        markLocalChange()
        isMuted = false
        volume = preset.volume
        activePreset = preset.name
        ha.setVolume(Int(preset.volume))
    }

    func toggleMute() {
        markLocalChange()
        isMuted.toggle()
        // media_player mute is independent of volume_level — the player keeps its
        // level while muted, so there's nothing to save/restore here.
        ha.setMute(isMuted)
    }

    /// Pull the authoritative volume + mute from HA (one request) and snap the UI
    /// to it. Called on launch and every time the popover opens. Skips applying
    /// while a local change is still settling, so it never clobbers a fresh adjustment.
    func syncFromRemote() {
        Task {
            let (remoteVol, remoteMuted) = await ha.fetchCurrentState()
            hasSyncedInitialVolume = true

            guard !isLocalChange else { return }

            if let remoteVol {
                let newVol = Double(remoteVol)
                if volume != newVol {
                    volume = newVol
                    updateActivePreset()
                }
            }
            if let remoteMuted, isMuted != remoteMuted {
                isMuted = remoteMuted
            }
        }
    }

    // MARK: - Helpers

    private func updateActivePreset() {
        activePreset = Self.activePreset(for: volume, in: presets)
    }
}
