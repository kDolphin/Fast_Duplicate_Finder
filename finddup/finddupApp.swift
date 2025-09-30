import SwiftUI

@main
struct FindupApp: App {
    @ObservedObject private var localization = LocalizationManager.shared
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(localization)
                .frame(
                    minWidth: AppTheme.windowMinWidth,
                    minHeight: AppTheme.windowMinHeight
                )
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    localization.reloadFromSystem()
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.expanded)
        .defaultSize(width: 1200, height: 780)
        .commands {
            // Standard macOS Settings menu item + ⌘,
            CommandGroup(replacing: .appSettings) {
                Button("settings.title".localized) {
                    openSettingsWindow()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
        
        // Native Settings window (also opens via ⌘, / menu)
        Settings {
            SettingsView(isPreferencesScene: true)
                .environmentObject(localization)
        }
    }
    
    private func openSettingsWindow() {
        // Prefer the SwiftUI Settings scene window
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
