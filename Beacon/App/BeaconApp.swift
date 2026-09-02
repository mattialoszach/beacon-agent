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
                .tint(BeaconPalette.blueViolet)
                .frame(minWidth: 900, minHeight: 620)
                .task { controller.start() }
        }
        .defaultSize(width: 1080, height: 720)

        MenuBarExtra {
            BeaconMenuView()
                .environmentObject(controller)
                .tint(BeaconPalette.blueViolet)
        } label: {
            Image(systemName: controller.isObserving ? "scope" : "scope")
                .symbolVariant(controller.isObserving ? .fill : .none)
        }

        Settings {
            SettingsView()
                .environmentObject(controller)
                .environmentObject(appPreferences)
                .tint(BeaconPalette.blueViolet)
                .frame(width: 620, height: 450)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var previewPrompt: FloatingPromptController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        guard BeaconLaunchOptions.isThinkingPreview(arguments: CommandLine.arguments) else { return }

        let prompt = FloatingPromptController()
        previewPrompt = prompt
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak prompt] in
            prompt?.show(
                onSubmit: { _ in },
                onCancel: { self?.previewPrompt = nil }
            )
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

enum BeaconLaunchOptions {
    static let thinkingPreview = "--preview-thinking"

    static func isThinkingPreview(arguments: [String]) -> Bool {
        arguments.contains(thinkingPreview)
    }
}
