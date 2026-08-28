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

            let store = ModelConfigurationStore(
                defaults: defaults,
                apiKeyStorage: InMemoryAPIKeyStorage()
            )

            XCTAssertEqual(store.provider, .accessibility)
            XCTAssertEqual(defaults.string(forKey: "models.provider"), ModelProviderChoice.accessibility.rawValue)
            XCTAssertNil(defaults.object(forKey: "models.processingMode"))
        }
    }

    func testLegacyQualityModePreservesProviderAndIsRemoved() {
        withDefaults { defaults in
            defaults.set(ModelProviderChoice.apple.rawValue, forKey: "models.provider")
            defaults.set("Best Quality", forKey: "models.processingMode")

            let store = ModelConfigurationStore(
                defaults: defaults,
                apiKeyStorage: InMemoryAPIKeyStorage()
            )

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

    func testOpenAIModelUsesRecommendedDefaultAndPersistsSelection() {
        withDefaults { defaults in
            let storage = InMemoryAPIKeyStorage()
            let store = ModelConfigurationStore(defaults: defaults, apiKeyStorage: storage)

            XCTAssertEqual(store.openAIModel, .terra)

            store.openAIModel = .luna

            XCTAssertEqual(
                ModelConfigurationStore(defaults: defaults, apiKeyStorage: storage).openAIModel,
                .luna
            )
        }
    }

    func testUnsupportedFreeFormOpenAIModelMigratesToRecommendedChoice() {
        withDefaults { defaults in
            defaults.set("gpt-5-mini", forKey: "models.openAIModel")

            let store = ModelConfigurationStore(
                defaults: defaults,
                apiKeyStorage: InMemoryAPIKeyStorage()
            )

            XCTAssertEqual(store.openAIModel, .terra)
            XCTAssertEqual(defaults.string(forKey: "models.openAIModel"), OpenAIModelChoice.terra.rawValue)
        }
    }

    func testStoredAPIKeyCanBeRemoved() throws {
        try withDefaults { defaults in
            let storage = InMemoryAPIKeyStorage(value: "sk-test-key")
            let store = ModelConfigurationStore(defaults: defaults, apiKeyStorage: storage)

            XCTAssertTrue(store.hasStoredAPIKey)

            try store.removeAPIKey()

            XCTAssertNil(storage.value)
            XCTAssertEqual(store.apiKey, "")
            XCTAssertFalse(store.hasStoredAPIKey)
        }
    }

    func testFailedAPIKeyRemovalKeepsInMemoryCredentialState() throws {
        try withDefaults { defaults in
            let storage = InMemoryAPIKeyStorage(value: "sk-test-key")
            storage.deleteError = TestCredentialError.deleteFailed
            let store = ModelConfigurationStore(defaults: defaults, apiKeyStorage: storage)

            XCTAssertThrowsError(try store.removeAPIKey())
            XCTAssertEqual(store.apiKey, "sk-test-key")
            XCTAssertTrue(store.hasStoredAPIKey)
        }
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suiteName = "SettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }
}

private final class InMemoryAPIKeyStorage: APIKeyStorage {
    var value: String?
    var deleteError: Error?

    init(value: String? = nil) {
        self.value = value
    }

    func read() -> String? {
        value
    }

    func write(_ value: String) throws {
        self.value = value.isEmpty ? nil : value
    }

    func delete() throws {
        if let deleteError { throw deleteError }
        value = nil
    }
}

private enum TestCredentialError: Error {
    case deleteFailed
}
