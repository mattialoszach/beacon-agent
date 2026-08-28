import AppKit
import Foundation

@MainActor
final class PrivacySettingsStore: ObservableObject {
    @Published private(set) var excludedBundleIdentifiers: Set<String>
    @Published var cloudProcessingEnabled: Bool {
        didSet { defaults.set(cloudProcessingEnabled, forKey: Keys.cloudProcessingEnabled) }
    }
    @Published var cloudVisionEnabled: Bool {
        didSet { defaults.set(cloudVisionEnabled, forKey: Keys.cloudVisionEnabled) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        excludedBundleIdentifiers = Set(defaults.stringArray(forKey: Keys.excludedApps) ?? Self.sensibleDefaults)
        cloudProcessingEnabled = defaults.bool(forKey: Keys.cloudProcessingEnabled)
        cloudVisionEnabled = defaults.bool(forKey: Keys.cloudVisionEnabled)
    }

    func isExcluded(bundleIdentifier: String?) -> Bool {
        bundleIdentifier.map(excludedBundleIdentifiers.contains) ?? false
    }

    func setExcluded(_ excluded: Bool, bundleIdentifier: String) {
        if excluded { excludedBundleIdentifiers.insert(bundleIdentifier) }
        else { excludedBundleIdentifiers.remove(bundleIdentifier) }
        defaults.set(Array(excludedBundleIdentifiers).sorted(), forKey: Keys.excludedApps)
    }

    var excludedApplications: [(bundleID: String, name: String)] {
        excludedBundleIdentifiers.map { bundleID in
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            let name = url?.deletingPathExtension().lastPathComponent ?? bundleID
            return (bundleID, name)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private enum Keys {
        static let excludedApps = "privacy.excludedBundleIdentifiers"
        static let cloudProcessingEnabled = "privacy.cloudProcessingEnabled"
        static let cloudVisionEnabled = "privacy.cloudVisionEnabled"
    }

    private static let sensibleDefaults = [
        "com.1password.1password",
        "com.apple.keychainaccess",
        "org.whispersystems.signal-desktop"
    ]
}
