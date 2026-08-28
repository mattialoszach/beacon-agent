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
                Text("Screenshots are redacted locally. Beacon's default accessibility matcher does not send any data off your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
