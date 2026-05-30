import SwiftUI
import AppKit
import Combine
import ServiceManagement
import Sparkle

@main
struct HAMenubarVolumeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No visible window — everything runs from the menu bar
        Settings { EmptyView() }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var eventMonitor: Any?

    /// Drives Sparkle automatic + manual update checks (feed URL and public key
    /// come from Info.plist: SUFeedURL / SUPublicEDKey).
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide Dock icon — pure menu bar app
        NSApp.setActivationPolicy(.accessory)

        // Status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "hifispeaker.fill", accessibilityDescription: "Volume")
            button.image?.size = NSSize(width: 16, height: 16)
            button.action = #selector(togglePopover)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Popover
        popover = NSPopover()
        popover.contentSize = NSSize(width: 280, height: 380)
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: VolumePopoverView())

        // Close popover when clicking outside
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePopover()
        }

        // Scroll on the menu bar icon to adjust volume
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let button = self.statusItem.button,
                  event.window == button.window else { return event }
            let delta = event.scrollingDeltaY
            if delta != 0 {
                let model = VolumeModel.shared
                let step = delta > 0 ? 2.0 : -2.0
                let newVol = max(0, min(100, model.volume + step))
                model.setVolume(newVol)
            }
            return event
        }

        // Register global hotkey: ⌥⌘V to toggle popover
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Option + Command + V
            if event.modifierFlags.contains([.option, .command]) && event.keyCode == 9 {
                self?.togglePopover()
            }
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }

        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            showContextMenu(from: button)
            return
        }

        if popover.isShown {
            closePopover()
        } else {
            VolumeModel.shared.refreshFromRemote()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func closePopover() {
        if popover.isShown { popover.performClose(nil) }
    }

    private func showContextMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()
        let about = menu.addItem(withTitle: "About Menubar Volume", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        let updates = menu.addItem(withTitle: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        updates.target = updaterController
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        button.performClick(nil)
        // Reset so left-click works again
        statusItem.menu = nil
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

// MARK: - Launch at Login

/// Wraps `SMAppService` so the app can register itself as a login item,
/// letting it start automatically after a reboot.
final class LoginItemManager: ObservableObject {
    static let shared = LoginItemManager()

    @Published private(set) var isEnabled: Bool
    @Published var lastError: String?

    private init() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    /// Re-read the current registration status from the system.
    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    /// Register or unregister the app as a login item.
    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            Log.d("[LoginItem] \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)")
        }
        refresh()
    }
}
