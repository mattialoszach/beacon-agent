import AppKit
import SwiftUI

@main
struct BeaconApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = BeaconController()
    @StateObject private var appPreferences = AppPreferencesStore()

    var body: some Scene {
        Window("Beacon", id: "main") {
            MainWindowView()
                .environmentObject(controller)
                .environmentObject(appPreferences)
                .frame(minWidth: 900, minHeight: 620)
                .task { controller.start() }
        }
        .defaultSize(width: 1080, height: 720)

        MenuBarExtra {
            BeaconMenuView()
                .environmentObject(controller)
        } label: {
            Image(systemName: controller.isObserving ? "scope" : "scope")
                .symbolVariant(controller.isObserving ? .fill : .none)
        }

        Settings {
            SettingsView()
                .environmentObject(controller)
                .environmentObject(appPreferences)
                .frame(width: 620, height: 450)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
