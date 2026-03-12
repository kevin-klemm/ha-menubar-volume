import Foundation
import SwiftUI
import Combine

/// Manages communication with Home Assistant via REST + WebSocket APIs.
/// Stores configuration in UserDefaults so users can update settings from the UI.
class HomeAssistantManager: ObservableObject {
    static let shared = HomeAssistantManager()

    // MARK: - Published State

    @Published var isReachable: Bool = false
    @Published var lastError: String?
    @Published var currentRemoteVolume: Int?
    @Published var currentRemoteMute: Bool?

    // MARK: - Configuration (persisted in UserDefaults)

    @AppStorage("ha_base_url") var baseURL: String = "http://homeassistant.local:8123"
    @AppStorage("ha_entity_id") var entityID: String = "input_number.amplifier_volume"
    @AppStorage("ha_mute_entity_id") var muteEntityID: String = "switch.amplifier_mute"

    /// Token stored separately — ideally move to Keychain for production use.
    @AppStorage("ha_token") var token: String = ""

    var isConfigured: Bool {
        !baseURL.isEmpty && !token.isEmpty && !entityID.isEmpty
    }

    // MARK: - Private

    private var reachabilityTask: Task<Void, Never>?
    private let session: URLSession

    // WebSocket state
    private var webSocketTask: URLSessionWebSocketTask?
    private var wsMessageID: Int = 0
    private var wsReconnectTask: Task<Void, Never>?
    private var wsConnected = false

    /// Timestamp of the last volume/mute command sent FROM this app.
    /// Used to suppress echo events for a short window.
    private var lastLocalVolumeChange: Date = .distantPast
    private var lastLocalMuteChange: Date = .distantPast
    private let echoSuppressionWindow: TimeInterval = 1.5

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        session = URLSession(configuration: config)

        startReachabilityLoop()
        connectWebSocket()
    }

    // MARK: - Generic API Helper

    private func callService(domain: String, service: String, data: [String: Any], completion: @escaping (Bool, String?) -> Void) {
        let trimmedBase = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(trimmedBase)/api/services/\(domain)/\(service)") else {
            completion(false, "Invalid URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: data)

        // Debug: print what we're sending
        let bodyStr = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? "nil"
        print("[HA] POST \(url.absoluteString)")
        print("[HA] Body: \(bodyStr)")

        session.dataTask(with: request) { data, response, error in
            if let error {
                print("[HA] Network error: \(error.localizedDescription)")
                completion(false, error.localizedDescription)
                return
            }

            let http = response as? HTTPURLResponse
            let statusCode = http?.statusCode ?? 0
            let responseBody = data.flatMap { String(data: $0, encoding: .utf8) } ?? "(empty)"
            print("[HA] Response: \(statusCode) — \(responseBody.prefix(200))")

            let ok = (200...299).contains(statusCode)
            completion(ok, ok ? nil : "HTTP \(statusCode): \(responseBody.prefix(120))")
        }.resume()
    }

    // MARK: - Set Volume

    func setVolume(_ volume: Int) {
        guard isConfigured else {
            lastError = "Not configured"
            return
        }

        lastLocalVolumeChange = Date()
        let data: [String: Any] = ["entity_id": entityID, "value": Double(volume) / 100]
        callService(domain: "input_number", service: "set_value", data: data) { [weak self] ok, error in
            DispatchQueue.main.async {
                if ok {
                    self?.lastError = nil
                    self?.currentRemoteVolume = volume
                } else {
                    // Don't touch isReachable — only the reachability loop controls that
                    self?.lastError = error
                }
            }
        }
    }

    // MARK: - Mute Switch

    func setMute(_ muted: Bool) {
        guard isConfigured, !muteEntityID.isEmpty else {
            lastError = "Mute entity not configured"
            return
        }

        lastLocalMuteChange = Date()
        let service = muted ? "turn_on" : "turn_off"
        let data: [String: Any] = ["entity_id": muteEntityID]
        callService(domain: "switch", service: service, data: data) { [weak self] ok, error in
            DispatchQueue.main.async {
                if ok {
                    self?.lastError = nil
                } else {
                    self?.lastError = error
                }
            }
        }
    }

    // MARK: - Fetch Current Volume

    func fetchCurrentVolume() async -> Int? {
        guard isConfigured else { return nil }

        let trimmedBase = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(trimmedBase)/api/states/\(entityID)") else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        print("[HA] GET \(url.absoluteString)")

        do {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            print("[HA] States response: \(http?.statusCode ?? 0)")

            guard let http, (200...299).contains(http.statusCode) else { return nil }

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let stateStr = json["state"] as? String,
               let value = Double(stateStr) {
                let vol = Int(round(value * 100))
                await MainActor.run {
                    self.currentRemoteVolume = vol
                    self.isReachable = true
                }
                return vol
            }
        } catch {
            print("[HA] Fetch volume error: \(error.localizedDescription)")
        }
        return nil
    }

    // MARK: - Reachability (sole controller of isReachable)

    private func startReachabilityLoop() {
        reachabilityTask?.cancel()
        reachabilityTask = Task {
            while !Task.isCancelled {
                await checkReachability()
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    func restartReachability() {
        startReachabilityLoop()
        reconnectWebSocket()
    }

    private func checkReachability() async {
        let trimmedBase = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard isConfigured, let url = URL(string: "\(trimmedBase)/api/") else {
            await MainActor.run { self.isReachable = false }
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (_, response) = try await session.data(for: request)
            let ok = (response as? HTTPURLResponse).map { (200...299).contains($0.statusCode) } ?? false
            await MainActor.run {
                self.isReachable = ok
                if ok { self.lastError = nil }
            }
        } catch {
            await MainActor.run {
                self.isReachable = false
                self.lastError = error.localizedDescription
            }
        }
    }

    // MARK: - WebSocket (real-time state sync)

    /// Build the WebSocket URL from the REST base URL.
    private func wsURL() -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // http:// → ws://, https:// → wss://
        let wsBase = trimmed
            .replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://", with: "ws://")
        return URL(string: "\(wsBase)/api/websocket")
    }

    func connectWebSocket() {
        guard isConfigured, let url = wsURL() else { return }

        // Tear down any existing connection
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        wsConnected = false
        wsMessageID = 0

        print("[HA WS] Connecting to \(url.absoluteString)")

        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()

        // Start the receive loop
        receiveWSMessage()
    }

    func reconnectWebSocket() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        wsConnected = false
        connectWebSocket()
    }

    private func scheduleWSReconnect() {
        wsReconnectTask?.cancel()
        wsReconnectTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
            guard !Task.isCancelled else { return }
            await MainActor.run { self.connectWebSocket() }
        }
    }

    private func nextWSID() -> Int {
        wsMessageID += 1
        return wsMessageID
    }

    private func sendWSJSON(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else { return }
        print("[HA WS] >>> \(text.prefix(200))")
        webSocketTask?.send(.string(text)) { error in
            if let error { print("[HA WS] Send error: \(error.localizedDescription)") }
        }
    }

    private func receiveWSMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleWSText(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleWSText(text)
                    }
                @unknown default:
                    break
                }
                // Keep receiving
                self.receiveWSMessage()

            case .failure(let error):
                print("[HA WS] Receive error: \(error.localizedDescription)")
                self.wsConnected = false
                self.scheduleWSReconnect()
            }
        }
    }

    private func handleWSText(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        print("[HA WS] <<< type=\(type)")

        switch type {
        case "auth_required":
            // Authenticate
            sendWSJSON(["type": "auth", "access_token": token])

        case "auth_ok":
            print("[HA WS] Authenticated")
            wsConnected = true
            // Subscribe to state_changed events
            subscribeToStateChanges()
            // Also fetch current state of both entities to ensure we're in sync
            fetchCurrentStatesViaWS()

        case "auth_invalid":
            let msg = json["message"] as? String ?? "Invalid auth"
            print("[HA WS] Auth failed: \(msg)")
            DispatchQueue.main.async { self.lastError = "WS auth: \(msg)" }

        case "event":
            handleWSEvent(json)

        case "result":
            // Result of a subscription or get_states call
            if let success = json["success"] as? Bool, !success {
                let errMsg = (json["error"] as? [String: Any])?["message"] as? String ?? "Unknown"
                print("[HA WS] Command failed: \(errMsg)")
            }

        default:
            break
        }
    }

    private func subscribeToStateChanges() {
        let id = nextWSID()
        sendWSJSON([
            "id": id,
            "type": "subscribe_events",
            "event_type": "state_changed"
        ])
    }

    /// Fetch current state of volume + mute entities right after connecting,
    /// so we're immediately in sync even if events were missed.
    private func fetchCurrentStatesViaWS() {
        // Fetch volume entity
        let volID = nextWSID()
        sendWSJSON([
            "id": volID,
            "type": "call_service",
            "domain": "homeassistant",
            "service": "update_entity",
            "target": ["entity_id": entityID]
        ])
        // Trigger a REST fetch to update local state
        Task {
            if let vol = await fetchCurrentVolume() {
                await MainActor.run { self.currentRemoteVolume = vol }
            }
            await fetchCurrentMuteState()
        }
    }

    // MARK: - Fetch Current Mute State

    func fetchCurrentMuteState() async {
        guard isConfigured, !muteEntityID.isEmpty else { return }

        let trimmedBase = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(trimmedBase)/api/states/\(muteEntityID)") else { return }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return }

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let stateStr = json["state"] as? String {
                let muted = stateStr == "on"
                await MainActor.run { self.currentRemoteMute = muted }
            }
        } catch {
            print("[HA] Fetch mute state error: \(error.localizedDescription)")
        }
    }

    // MARK: - WebSocket Event Handling

    private func handleWSEvent(_ json: [String: Any]) {
        guard let event = json["event"] as? [String: Any],
              let eventData = event["data"] as? [String: Any],
              let changedEntityID = eventData["entity_id"] as? String,
              let newState = eventData["new_state"] as? [String: Any],
              let stateValue = newState["state"] as? String else { return }

        if changedEntityID == entityID {
            handleVolumeStateChange(stateValue)
        } else if changedEntityID == muteEntityID {
            handleMuteStateChange(stateValue)
        }
    }

    private func handleVolumeStateChange(_ stateValue: String) {
        guard let value = Double(stateValue) else { return }
        let vol = Int(round(value * 100))
        print("[HA WS] Volume entity changed → \(vol)")

        // Suppress echoes from our own commands
        let elapsed = Date().timeIntervalSince(lastLocalVolumeChange)
        guard elapsed > echoSuppressionWindow else {
            print("[HA WS] Suppressing volume echo (sent \(String(format: "%.1f", elapsed))s ago)")
            return
        }

        DispatchQueue.main.async {
            self.currentRemoteVolume = vol
        }
    }

    private func handleMuteStateChange(_ stateValue: String) {
        let muted = stateValue == "on"
        print("[HA WS] Mute entity changed → \(muted)")

        // Suppress echoes from our own commands
        let elapsed = Date().timeIntervalSince(lastLocalMuteChange)
        guard elapsed > echoSuppressionWindow else {
            print("[HA WS] Suppressing mute echo (sent \(String(format: "%.1f", elapsed))s ago)")
            return
        }

        DispatchQueue.main.async {
            self.currentRemoteMute = muted
        }
    }
}
