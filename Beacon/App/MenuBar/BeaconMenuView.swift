import AppKit
import SwiftUI

struct BeaconMenuView: View {
    @EnvironmentObject private var controller: BeaconController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            Text("Beacon")
                .font(.headline)

            Button("Ask Beacon") { controller.showPrompt() }
                .keyboardShortcut("a")

            Divider()

            Toggle("Pause Screen Access", isOn: $controller.screenAccessPaused)
            LabeledContent("Current Model", value: controller.modelSettings.provider.rawValue)
            Label(
                controller.privacySettings.cloudProcessingEnabled ? "Cloud allowed" : "Local processing",
                systemImage: controller.privacySettings.cloudProcessingEnabled ? "cloud" : "lock.shield"
            )

            Divider()

            Button("Open Beacon") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            SettingsLink { Text("Settings…") }
            Button("Quit Beacon") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}
