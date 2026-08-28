import XCTest
@testable import Beacon

@MainActor
final class SettingsStoreTests: XCTestCase {
    func testDeveloperInspectorIsHiddenByDefaultAndPreferencePersists() {
        withDefaults { defaults in
            let store = AppPreferencesStore(defaults: defaults)
            XCTAssertFalse(store.showDeveloperInspector)

            store.showDeveloperInspector = true

            XCTAssertTrue(AppPreferencesStore(defaults: defaults).showDeveloperInspector)
        }
    }

    func testLegacyLocalOnlyOpenAISelectionMigratesToLocalProvider() {
        withDefaults { defaults in
            defaults.set(ModelProviderChoice.openAI.rawValue, forKey: "models.provider")
            defaults.set("Local Only", forKey: "models.processingMode")

            let store = ModelConfigurationStore(defaults: defaults)

            XCTAssertEqual(store.provider, .accessibility)
            XCTAssertEqual(defaults.string(forKey: "models.provider"), ModelProviderChoice.accessibility.rawValue)
            XCTAssertNil(defaults.object(forKey: "models.processingMode"))
        }
    }

    func testLegacyQualityModePreservesProviderAndIsRemoved() {
        withDefaults { defaults in
            defaults.set(ModelProviderChoice.apple.rawValue, forKey: "models.provider")
            defaults.set("Best Quality", forKey: "models.processingMode")

            let store = ModelConfigurationStore(defaults: defaults)

            XCTAssertEqual(store.provider, .apple)
            XCTAssertNil(defaults.object(forKey: "models.processingMode"))
        }
    }

    func testCloudVisionRequiresASeparatePersistedOptIn() {
        withDefaults { defaults in
            let settings = PrivacySettingsStore(defaults: defaults)
            XCTAssertFalse(settings.cloudVisionEnabled)

            settings.cloudVisionEnabled = true

            XCTAssertTrue(PrivacySettingsStore(defaults: defaults).cloudVisionEnabled)
        }
    }

    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "SettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults)
    }
}
