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

            if let completion = controller.completionMessage {
                Label("Finished", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                BeaconFormattedText(completion)
                if controller.canContinueCompletedGuide {
                    Button("Keep Guiding", systemImage: "arrow.clockwise") {
                        Task { await controller.continueGuiding() }
                    }
                }
                Divider()
            }

            if let confirmation = controller.confirmationMessage {
                BeaconFormattedText(confirmation)
                Button("Confirm Result") { Task { await controller.confirmResult(succeeded: true) } }
                Button("That Didn’t Work") { Task { await controller.confirmResult(succeeded: false) } }
                Divider()
            }

            Toggle("Pause Screen Access", isOn: $controller.screenAccessPaused)
            LabeledContent("Selected Model", value: controller.modelSettings.provider.rawValue)
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
