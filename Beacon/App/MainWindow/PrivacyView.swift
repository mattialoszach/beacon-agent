import AppKit
import SwiftUI

struct PrivacyView: View {
    @EnvironmentObject private var controller: BeaconController
    @State private var runningApps: [NSRunningApplication] = []

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
                    if let snapshot = controller.outboundImagePreview {
                        ScreenSnapshotImageView(
                            snapshot: snapshot,
                            variant: "privacy-preview",
                            maximumHeight: 220
                        )
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
                ForEach(listedApplications, id: \.bundleID) { entry in
                    Toggle(isOn: Binding(
                        get: { controller.privacySettings.isExcluded(bundleIdentifier: entry.bundleID) },
                        set: { controller.privacySettings.setExcluded($0, bundleIdentifier: entry.bundleID) }
                    )) {
                        HStack {
                            if let icon = entry.icon {
                                Image(nsImage: icon).resizable().frame(width: 22, height: 22)
                            }
                            VStack(alignment: .leading) {
                                Text(entry.name)
                                Text(entry.bundleID).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Privacy")
        .onAppear(perform: refreshRunningApplications)
        .onReceive(
            NSWorkspace.shared.notificationCenter
                .publisher(for: NSWorkspace.didLaunchApplicationNotification)
        ) { _ in refreshRunningApplications() }
        .onReceive(
            NSWorkspace.shared.notificationCenter
                .publisher(for: NSWorkspace.didTerminateApplicationNotification)
        ) { _ in refreshRunningApplications() }
    }

    /// Running applications plus every excluded bundle identifier, so an exclusion stays
    /// visible and removable after the application quits.
    private var listedApplications: [ApplicationEntry] {
        var entries = runningApps.map { app in
            ApplicationEntry(
                bundleID: app.bundleIdentifier ?? "",
                name: app.localizedName ?? app.bundleIdentifier ?? "",
                icon: app.icon
            )
        }
        let listed = Set(entries.map(\.bundleID))
        for bundleID in controller.privacySettings.excludedBundleIdentifiers where !listed.contains(bundleID) {
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            entries.append(ApplicationEntry(
                bundleID: bundleID,
                name: url?.deletingPathExtension().lastPathComponent ?? bundleID,
                icon: url.map { NSWorkspace.shared.icon(forFile: $0.path) }
            ))
        }
        return entries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func refreshRunningApplications() {
        runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .uniqued(by: \.bundleIdentifier)
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }
}

private struct ApplicationEntry {
    let bundleID: String
    let name: String
    let icon: NSImage?
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
