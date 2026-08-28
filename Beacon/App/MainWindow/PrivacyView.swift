import AppKit
import SwiftUI

struct PrivacyView: View {
    @EnvironmentObject private var controller: BeaconController

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .uniqued(by: \.bundleIdentifier)
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    var body: some View {
        Form {
            Section("Processing") {
                Toggle("Allow configured cloud providers", isOn: $controller.privacySettings.cloudProcessingEnabled)
                Toggle(
                    "Allow the redacted visual preview",
                    isOn: $controller.privacySettings.cloudVisionEnabled
                )
                .disabled(!controller.privacySettings.cloudProcessingEnabled)
                Text("Screenshots are redacted locally. Beacon's default accessibility matcher does not send any data off your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if controller.privacySettings.cloudVisionEnabled {
                Section("Exact outbound visual preview") {
                    if let snapshot = controller.outboundImagePreview,
                       let image = NSImage(data: snapshot.pngData) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: 220)
                            .accessibilityLabel("Exact outbound redacted visual preview")
                        Text("This locally redacted, numbered image was prepared for the latest OpenAI visual request. It is never used for excluded applications.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ContentUnavailableView(
                            "No visual preview sent",
                            systemImage: "eye.slash",
                            description: Text("A preview appears here after a visual OpenAI request. The exact image is redacted before it becomes eligible to leave your Mac.")
                        )
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: 150, alignment: .center)
                    }
                }
            }

            Section("Never capture these applications") {
                ForEach(runningApps, id: \.processIdentifier) { app in
                    let bundleID = app.bundleIdentifier ?? ""
                    Toggle(isOn: Binding(
                        get: { controller.privacySettings.isExcluded(bundleIdentifier: bundleID) },
                        set: { controller.privacySettings.setExcluded($0, bundleIdentifier: bundleID) }
                    )) {
                        HStack {
                            if let icon = app.icon { Image(nsImage: icon).resizable().frame(width: 22, height: 22) }
                            VStack(alignment: .leading) {
                                Text(app.localizedName ?? bundleID)
                                Text(bundleID).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Privacy")
    }
}

private extension Array {
    func uniqued<Key: Hashable>(by keyPath: KeyPath<Element, Key?>) -> [Element] {
        var seen = Set<Key>()
        return filter { element in
            guard let key = element[keyPath: keyPath] else { return false }
            return seen.insert(key).inserted
        }
    }
}
