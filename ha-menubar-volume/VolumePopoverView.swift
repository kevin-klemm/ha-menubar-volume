import SwiftUI
import AppKit

struct VolumePopoverView: View {
    @ObservedObject private var model = VolumeModel.shared
    @ObservedObject private var ha = HomeAssistantManager.shared
    @ObservedObject private var loginItem = LoginItemManager.shared
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            if showSettings {
                settingsView
            } else {
                mainView
            }
        }
        .frame(width: 280)
        .animation(.easeInOut(duration: 0.2), value: showSettings)
    }

    // MARK: - Main View

    private var mainView: some View {
        VStack(spacing: 0) {
            header
            Divider()
            volumeSection
            Divider()
            footer
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("AMPLIFIER")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Spacer()
            connectionBadge
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var connectionBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
                .overlay(
                    Circle()
                        .fill(statusColor.opacity(0.4))
                        .frame(width: 10, height: 10)
                        .opacity(ha.isReachable ? 0 : 1)
                        .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: ha.isReachable)
                )
            Text(statusText)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }

    private var statusColor: Color {
        if !ha.isConfigured { return .gray }
        return ha.isReachable ? .green : .orange
    }

    private var statusText: String {
        if !ha.isConfigured { return "Not configured" }
        return ha.isReachable ? "Connected" : "Unreachable"
    }

    // MARK: - Volume Section

    private var volumeSection: some View {
        VStack(spacing: 14) {
            // Volume readout + controls
            HStack(alignment: .center) {
                // Decrease button
                stepButton(icon: "minus", action: { model.stepVolume(by: -5) })

                Spacer()

                // Big volume number
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(model.isMuted ? "—" : "\(Int(model.volume))")
                        .font(.system(size: 42, weight: .thin, design: .rounded))
                        .foregroundColor(model.isMuted ? .secondary : .primary)
                        .frame(minWidth: 70, alignment: .trailing)
                        .contentTransition(.numericText())
                        .animation(.spring(response: 0.2), value: Int(model.volume))

                    Text("%")
                        .font(.system(size: 18, weight: .light))
                        .foregroundColor(.secondary)
                        .padding(.bottom, 4)
                }

                Spacer()

                // Increase button
                stepButton(icon: "plus", action: { model.stepVolume(by: 5) })
            }

            // Slider
            VolumeSlider(value: $model.volume, isMuted: model.isMuted) { newValue in
                model.setVolume(newValue)
            }
            .disabled(!ha.isReachable)
            .opacity(ha.isReachable ? 1 : 0.4)

            // Mute bar
            Button(action: { model.toggleMute() }) {
                HStack(spacing: 6) {
                    Image(systemName: model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 11))
                    Text(model.isMuted ? "Unmute" : "Mute")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(model.isMuted ? .orange : .secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(model.isMuted ? Color.orange.opacity(0.12) : Color.primary.opacity(0.04))
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func stepButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 60, height: 60)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .disabled(!ha.isReachable)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button(action: { showSettings = true }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)

            Spacer()

            if let error = ha.lastError {
                Text(error)
                    .font(.system(size: 9))
                    .foregroundColor(.orange)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
            }

            Button("Quit") { NSApp.terminate(nil) }
                .font(.system(size: 11))
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Settings View

    private var settingsView: some View {
        VStack(spacing: 0) {
            // Settings header
            HStack {
                Button(action: { showSettings = false }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Back")
                            .font(.system(size: 12))
                    }
                    .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                Spacer()
                Text("Settings")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                // Balance spacer
                Color.clear.frame(width: 50, height: 1)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                settingsField(label: "HA Base URL", text: $ha.baseURL, placeholder: "http://homeassistant.local:8123")
                settingsField(label: "Access Token", text: $ha.token, placeholder: "Long-lived access token", isSecure: true)
                settingsField(label: "Volume Entity", text: $ha.entityID, placeholder: "input_number.amplifier_volume")
                settingsField(label: "Mute Switch Entity", text: $ha.muteEntityID, placeholder: "switch.amplifier_mute")

                Button(action: {
                    ha.restartReachability()
                }) {
                    Text("Test Connection")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)

                HStack(spacing: 4) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                    Text(statusText)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                Divider()

                Toggle(isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.setEnabled($0) }
                )) {
                    Text("Launch at login")
                        .font(.system(size: 12))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .onAppear { loginItem.refresh() }

                if let loginError = loginItem.lastError {
                    Text(loginError)
                        .font(.system(size: 9))
                        .foregroundColor(.orange)
                        .lineLimit(2)
                }

                Text("Shortcut: ⌥⌘V to toggle popover\nScroll on menu bar icon to adjust")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.7))
                    .lineSpacing(2)
            }
            .padding(16)
        }
    }

    private func settingsField(label: String, text: Binding<String>, placeholder: String, isSecure: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
            Group {
                if isSecure {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                }
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, design: .monospaced))
        }
    }
}

// MARK: - Custom Slider

struct VolumeSlider: View {
    @Binding var value: Double
    let isMuted: Bool
    let onChanged: (Double) -> Void

    @State private var isDragging = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Track background
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 6)

                // Filled track
                RoundedRectangle(cornerRadius: 4)
                    .fill(trackColor)
                    .frame(width: max(0, geo.size.width * CGFloat(value / 100)), height: 6)
                    .animation(.interactiveSpring(response: 0.15), value: value)

                // Thumb
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.15), radius: isDragging ? 4 : 2, y: 1)
                    .frame(width: isDragging ? 20 : 16, height: isDragging ? 20 : 16)
                    .offset(x: max(0, min(geo.size.width - 16, geo.size.width * CGFloat(value / 100) - 8)))
                    .animation(.interactiveSpring(response: 0.15), value: value)
                    .animation(.spring(response: 0.2), value: isDragging)
            }
            .frame(height: 20)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        isDragging = true
                        let newValue = max(0, min(100, Double(drag.location.x / geo.size.width) * 100))
                        value = newValue
                        onChanged(newValue)
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
        }
        .frame(height: 20)
    }

    private var trackColor: some ShapeStyle {
        if isMuted { return AnyShapeStyle(Color.orange.opacity(0.4)) }
        return AnyShapeStyle(Color.accentColor)
    }
}
