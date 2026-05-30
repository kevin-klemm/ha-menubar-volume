import Foundation
import SwiftUI
import Combine
import Security

/// Result of validating the configured entity against Home Assistant.
enum EntityStatus: Equatable {
    case unknown            // not checked yet
    case checking
    case ok(String)         // exists & supports volume; payload is the friendly name
    case notFound           // entity_id doesn't exist in HA
    case wrongDomain        // not a media_player.* entity
    case noVolumeSupport    // media_player that can't set volume
    case error(String)
}

/// Manages communication with Home Assistant via REST + WebSocket APIs.
/// Stores configuration in UserDefaults so users can update settings from the UI.
class HomeAssistantManager: ObservableObject {
    static let shared = HomeAssistantManager()

    // MARK: - Published State

    @Published var isReachable: Bool = false
    @Published var lastError: String?
    @Published var currentRemoteVolume: Int?
    @Published var currentRemoteMute: Bool?
    @Published var entityStatus: EntityStatus = .unknown
    /// The entity's `friendly_name` from HA, once known.
    @Published var friendlyName: String?

    /// Name to show in the popover header: the HA friendly name when known,
    /// otherwise a readable fallback derived from the entity_id.
    var displayName: String {
        if let friendlyName, !friendlyName.isEmpty { return friendlyName }
        return Self.displayName(forEntityID: entityID)
    }

    // MARK: - Configuration (persisted in UserDefaults)

    @AppStorage("ha_base_url") var baseURL: String = "http://homeassistant.local:8123"
    /// A `media_player` entity (a single player or an HA media_player group).
    @AppStorage("ha_entity_id") var entityID: String = "media_player.living_room"

    /// Long-lived access token, backed by the Keychain rather than plaintext UserDefaults.
    @Published var token: String = "" {
        didSet {
            guard token != oldValue else { return }
            Keychain.set(token, account: Self.tokenKeychainKey)
        }
    }

    private static let tokenKeychainKey = "ha_token"

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

        // Load the token from the Keychain, migrating any value previously stored
        // in plaintext UserDefaults by older builds.
        if let stored = Keychain.get(account: Self.tokenKeychainKey) {
            token = stored
        } else if let legacy = UserDefaults.standard.string(forKey: Self.tokenKeychainKey),
                  !legacy.isEmpty {
            token = legacy // didSet writes it to the Keychain
            UserDefaults.standard.removeObject(forKey: Self.tokenKeychainKey)
        }

        startReachabilityLoop()
        connectWebSocket()
    }

    // MARK: - Pure Helpers (internal for testability)

    /// Convert a REST/WebSocket base URL to its WebSocket equivalent.
    static func wsURL(from baseURL: String) -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return nil }
        let wsBase = trimmed
            .replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://", with: "ws://")
        return URL(string: "\(wsBase)/api/websocket")
    }

    /// Convert a `media_player` `volume_level` attribute (0.0–1.0) into a 0–100 integer.
    /// Returns nil when the attribute is missing (e.g. the player is off).
    static func parseVolumeLevel(_ value: Any?) -> Int? {
        guard let level = value as? Double else { return nil }
        return Int(round(level * 100))
    }

    /// Read a `media_player` `is_volume_muted` attribute into a Bool.
    static func parseMuteFlag(_ value: Any?) -> Bool {
        value as? Bool ?? false
    }

    /// Whether a `media_player`'s `supported_features` bitmask includes VOLUME_SET (4).
    static func supportsVolumeSet(_ supportedFeatures: Int?) -> Bool {
        guard let features = supportedFeatures else { return false }
        return (features & 4) != 0 // MediaPlayerEntityFeature.VOLUME_SET
    }

    /// Derive a readable label from an entity_id, e.g.
    /// `media_player.living_room` → "Living Room".
    static func displayName(forEntityID entityID: String) -> String {
        let slug = entityID.split(separator: ".").last.map(String.init) ?? entityID
        let words = slug.split(separator: "_").map { $0.capitalized }
        return words.isEmpty ? entityID : words.joined(separator: " ")
    }

    // MARK: - Generic API Helper

    @discardableResult
    private func callService(domain: String, service: String, data: [String: Any]) async -> (ok: Bool, error: String?) {
        let trimmedBase = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(trimmedBase)/api/services/\(domain)/\(service)") else {
            return (false, "Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: data)

        let bodyStr = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? "nil"
        Log.d("[HA] POST \(url.absoluteString)")
        Log.d("[HA] Body: \(bodyStr)")

        do {
            let (responseData, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            let statusCode = http?.statusCode ?? 0
            let responseBody = String(data: responseData, encoding: .utf8) ?? "(empty)"
            Log.d("[HA] Response: \(statusCode) — \(responseBody.prefix(200))")

            if (200...299).contains(statusCode) {
                return (true, nil)
            } else {
                return (false, "HTTP \(statusCode): \(responseBody.prefix(120))")
            }
        } catch {
            Log.d("[HA] Network error: \(error.localizedDescription)")
            return (false, error.localizedDescription)
        }
    }

    // MARK: - Set Volume

    func setVolume(_ volume: Int) {
        guard isConfigured else {
            lastError = "Not configured"
            return
        }

        lastLocalVolumeChange = Date()
        let data: [String: Any] = ["entity_id": entityID, "volume_level": Double(volume) / 100]
        Task {
            let (ok, error) = await callService(domain: "media_player", service: "volume_set", data: data)
            if ok {
                lastError = nil
                currentRemoteVolume = volume
            } else {
                // Don't touch isReachable — only the reachability loop controls that
                lastError = error
            }
        }
    }

    // MARK: - Mute

    func setMute(_ muted: Bool) {
        guard isConfigured else {
            lastError = "Not configured"
            return
        }

        lastLocalMuteChange = Date()
        let data: [String: Any] = ["entity_id": entityID, "is_volume_muted": muted]
        Task {
            let (ok, error) = await callService(domain: "media_player", service: "volume_mute", data: data)
            if ok {
                lastError = nil
            } else {
                lastError = error
            }
        }
    }

    // MARK: - Fetch Current State

    /// Read the media_player's current volume + mute from HA in a single request,
    /// so both reflect the same snapshot. Returns nil for an attribute the player
    /// doesn't expose (e.g. while it's off). Updates the published mirrors too.
    @discardableResult
    func fetchCurrentState() async -> (volume: Int?, muted: Bool?) {
        guard isConfigured else { return (nil, nil) }

        let trimmedBase = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(trimmedBase)/api/states/\(entityID)") else { return (nil, nil) }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        Log.d("[HA] GET \(url.absoluteString)")

        do {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            Log.d("[HA] States response: \(http?.statusCode ?? 0)")

            guard let http, (200...299).contains(http.statusCode) else { return (nil, nil) }
            isReachable = true

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let attributes = json["attributes"] as? [String: Any] else { return (nil, nil) }

            if let name = attributes["friendly_name"] as? String { friendlyName = name }
            let vol = Self.parseVolumeLevel(attributes["volume_level"])
            let muted = attributes["is_volume_muted"] != nil ? Self.parseMuteFlag(attributes["is_volume_muted"]) : nil
            if let vol { currentRemoteVolume = vol }
            if let muted { currentRemoteMute = muted }
            return (vol, muted)
        } catch {
            Log.d("[HA] Fetch state error: \(error.localizedDescription)")
            return (nil, nil)
        }
    }

    // MARK: - Entity Validation

    /// Verify the configured entity exists in HA, is a media_player, and supports
    /// volume. Result is published via `entityStatus` for the Settings UI.
    func validateEntity() async {
        guard isConfigured else {
            entityStatus = .error("Enter a URL, token, and entity")
            return
        }
        guard entityID.hasPrefix("media_player.") else {
            entityStatus = .wrongDomain
            return
        }

        entityStatus = .checking

        let trimmedBase = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(trimmedBase)/api/states/\(entityID)") else {
            entityStatus = .error("Invalid URL")
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0

            if code == 404 {
                entityStatus = .notFound
                return
            }
            guard (200...299).contains(code) else {
                entityStatus = .error("HTTP \(code)")
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let attributes = json["attributes"] as? [String: Any] else {
                entityStatus = .error("Unexpected response")
                return
            }

            let name = (attributes["friendly_name"] as? String) ?? entityID
            friendlyName = attributes["friendly_name"] as? String
            if Self.supportsVolumeSet(attributes["supported_features"] as? Int) {
                entityStatus = .ok(name)
            } else {
                entityStatus = .noVolumeSupport
            }
        } catch {
            entityStatus = .error(error.localizedDescription)
        }
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
            isReachable = false
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (_, response) = try await session.data(for: request)
            let ok = (response as? HTTPURLResponse).map { (200...299).contains($0.statusCode) } ?? false
            isReachable = ok
            if ok { lastError = nil }
        } catch {
            isReachable = false
            lastError = error.localizedDescription
        }
    }

    // MARK: - WebSocket (real-time state sync)

    func connectWebSocket() {
        guard isConfigured, let url = Self.wsURL(from: baseURL) else { return }

        // Tear down any existing connection
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        wsConnected = false
        wsMessageID = 0

        Log.d("[HA WS] Connecting to \(url.absoluteString)")

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
            connectWebSocket()
        }
    }

    private func nextWSID() -> Int {
        wsMessageID += 1
        return wsMessageID
    }

    private func sendWSJSON(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else { return }
        Log.d("[HA WS] >>> \(text.prefix(200))")
        webSocketTask?.send(.string(text)) { error in
            if let error { Log.d("[HA WS] Send error: \(error.localizedDescription)") }
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
                Log.d("[HA WS] Receive error: \(error.localizedDescription)")
                Task { @MainActor [weak self] in
                    self?.wsConnected = false
                    self?.scheduleWSReconnect()
                }
            }
        }
    }

    private func handleWSText(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        Log.d("[HA WS] <<< type=\(type)")

        switch type {
        case "auth_required":
            sendWSJSON(["type": "auth", "access_token": token])

        case "auth_ok":
            Log.d("[HA WS] Authenticated")
            Task { @MainActor [weak self] in
                self?.wsConnected = true
                self?.subscribeToStateChanges()
                self?.fetchCurrentStatesViaWS()
            }

        case "auth_invalid":
            let msg = json["message"] as? String ?? "Invalid auth"
            Log.d("[HA WS] Auth failed: \(msg)")
            Task { @MainActor [weak self] in
                self?.lastError = "WS auth: \(msg)"
            }

        case "event":
            handleWSEvent(json)

        case "result":
            if let success = json["success"] as? Bool, !success {
                let errMsg = (json["error"] as? [String: Any])?["message"] as? String ?? "Unknown"
                Log.d("[HA WS] Command failed: \(errMsg)")
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

    /// Fetch current state right after connecting, so we're immediately in sync
    /// even if events were missed. Asks HA to refresh the entity first.
    private func fetchCurrentStatesViaWS() {
        let volID = nextWSID()
        sendWSJSON([
            "id": volID,
            "type": "call_service",
            "domain": "homeassistant",
            "service": "update_entity",
            "target": ["entity_id": entityID]
        ])
        Task { await fetchCurrentState() }
    }

    // MARK: - WebSocket Event Handling

    private func handleWSEvent(_ json: [String: Any]) {
        guard let event = json["event"] as? [String: Any],
              let eventData = event["data"] as? [String: Any],
              let changedEntityID = eventData["entity_id"] as? String,
              changedEntityID == entityID,
              let newState = eventData["new_state"] as? [String: Any],
              let attributes = newState["attributes"] as? [String: Any] else { return }

        if let vol = Self.parseVolumeLevel(attributes["volume_level"]) {
            handleVolumeChange(vol)
        }
        if attributes["is_volume_muted"] != nil {
            handleMuteChange(Self.parseMuteFlag(attributes["is_volume_muted"]))
        }
    }

    private func handleVolumeChange(_ vol: Int) {
        Log.d("[HA WS] Volume changed → \(vol)")

        // Suppress echoes from our own commands
        let elapsed = Date().timeIntervalSince(lastLocalVolumeChange)
        guard elapsed > echoSuppressionWindow else {
            Log.d("[HA WS] Suppressing volume echo (sent \(String(format: "%.1f", elapsed))s ago)")
            return
        }

        Task { @MainActor [weak self] in
            self?.currentRemoteVolume = vol
        }
    }

    private func handleMuteChange(_ muted: Bool) {
        Log.d("[HA WS] Mute changed → \(muted)")

        // Suppress echoes from our own commands
        let elapsed = Date().timeIntervalSince(lastLocalMuteChange)
        guard elapsed > echoSuppressionWindow else {
            Log.d("[HA WS] Suppressing mute echo (sent \(String(format: "%.1f", elapsed))s ago)")
            return
        }

        Task { @MainActor [weak self] in
            self?.currentRemoteMute = muted
        }
    }
}

// MARK: - Debug Logging

/// Lightweight logger that only emits in DEBUG builds, so release builds don't
/// write request bodies and entity state to the system log.
enum Log {
    static func d(_ message: @autoclosure () -> String) {
        #if DEBUG
        Swift.print(message())
        #endif
    }
}

// MARK: - Keychain

/// Minimal generic-password Keychain wrapper for storing the HA access token.
enum Keychain {
    private static let service = "kklemm.ha-menubar-volume"

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Store (or, for an empty value, delete) a string for the given account.
    static func set(_ value: String, account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard !value.isEmpty else { return }
        var attributes = baseQuery(account: account)
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    /// Fetch the stored string for the given account, or nil if absent.
    static func get(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
