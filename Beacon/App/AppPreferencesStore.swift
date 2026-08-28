import Foundation

@MainActor
final class AppPreferencesStore: ObservableObject {
    @Published var showDeveloperInspector: Bool {
        didSet { defaults.set(showDeveloperInspector, forKey: Keys.showDeveloperInspector) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showDeveloperInspector = defaults.bool(forKey: Keys.showDeveloperInspector)
    }

    private enum Keys {
        static let showDeveloperInspector = "developer.showInspector"
    }
}
