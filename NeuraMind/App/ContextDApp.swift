import SwiftUI

@main
struct NeuraMindApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    /// All services live in the singleton -- not in @State on this struct.
    private let services = ServiceContainer.shared

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }

    init() {
        // Register the global hotkeys
        HotkeyManager.shared.onHotkey = {
            Task { @MainActor in
                ServiceContainer.shared.panelController?.toggle()
            }
        }
        // Cmd+Shift+N -> NeuraMind Daily Assistant panel
        HotkeyManager.shared.onSecondaryHotkey = {
            Task { @MainActor in
                ServiceContainer.shared.neuraMindController?.toggle()
            }
        }
        HotkeyManager.shared.register()
        HotkeyManager.shared.registerSecondary()
    }
}
