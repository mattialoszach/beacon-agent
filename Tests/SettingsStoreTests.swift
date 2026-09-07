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

    func testStoredAPIKeyCanBeRemoved() async throws {
        try await withAsyncDefaults { defaults in
            let storage = InMemoryAPIKeyStorage(value: "sk-test-key")
            let store = ModelConfigurationStore(defaults: defaults, apiKeyStorage: storage)
            await store.loadAPIKeyIfNeeded()

            XCTAssertTrue(store.hasStoredAPIKey)

            try await store.removeAPIKey()

            XCTAssertNil(storage.value)
            XCTAssertEqual(store.apiKey, "")
            XCTAssertFalse(store.hasStoredAPIKey)
        }
    }

    func testQueuedAPIKeySavesPreserveEachSubmittedDraft() async throws {
        try await withAsyncDefaults { defaults in
            let storage = BlockingAPIKeyStorage()
            let store = ModelConfigurationStore(defaults: defaults, apiKeyStorage: storage)
            store.apiKey = "sk-first-value"
            let firstSave = Task { try await store.saveAPIKey() }
            defer { storage.releaseFirstWrite() }
            try await waitUntil { storage.writes == ["sk-first-value"] }

            store.apiKey = "sk-second-value"
            let secondSave = Task { try await store.saveAPIKey() }
            await Task.yield()
            storage.releaseFirstWrite()
            try await firstSave.value
            try await secondSave.value

            XCTAssertEqual(storage.writes, ["sk-first-value", "sk-second-value"])
            XCTAssertEqual(store.apiKey, "sk-second-value")
            XCTAssertEqual(store.storedAPIKey, "sk-second-value")
        }
    }

    func testFailedAPIKeyRemovalKeepsInMemoryCredentialState() async {
        await withAsyncDefaults { defaults in
            let storage = InMemoryAPIKeyStorage(value: "sk-test-key")
            storage.deleteError = TestCredentialError.deleteFailed
            let store = ModelConfigurationStore(defaults: defaults, apiKeyStorage: storage)
            await store.loadAPIKeyIfNeeded()

            do {
                try await store.removeAPIKey()
                XCTFail("Expected credential deletion to fail")
            } catch {
                XCTAssertEqual(error as? TestCredentialError, .deleteFailed)
            }
            XCTAssertEqual(store.apiKey, "sk-test-key")
            XCTAssertTrue(store.hasStoredAPIKey)
        }
    }

    func testAPIKeyReadIsDeferredUntilRequested() async {
        await withAsyncDefaults { defaults in
            let storage = InMemoryAPIKeyStorage(value: "sk-test-key")
            let store = ModelConfigurationStore(defaults: defaults, apiKeyStorage: storage)

            XCTAssertEqual(storage.readCount, 0)
            XCTAssertFalse(store.hasStoredAPIKey)

            await store.loadAPIKeyIfNeeded()

            XCTAssertEqual(storage.readCount, 1)
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

    private func withAsyncDefaults(_ body: (UserDefaults) async throws -> Void) async rethrows {
        let suiteName = "SettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try await body(defaults)
    }

    private func waitUntil(
        _ condition: () -> Bool,
        timeout: Duration = .seconds(2)
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "Timed out waiting for the credential operation")
    }
}

private final class InMemoryAPIKeyStorage: APIKeyStorage, @unchecked Sendable {
    var value: String?
    var deleteError: Error?
    private(set) var readCount = 0

    init(value: String? = nil) {
        self.value = value
    }

    func read() -> String? {
        readCount += 1
        return value
    }

    func write(_ value: String) throws {
        self.value = value.isEmpty ? nil : value
    }

    func delete() throws {
        if let deleteError { throw deleteError }
        value = nil
    }
}

private enum TestCredentialError: Error, Equatable {
    case deleteFailed
}

private final class BlockingAPIKeyStorage: APIKeyStorage, @unchecked Sendable {
    private let lock = NSLock()
    private let firstWriteGate = DispatchSemaphore(value: 0)
    private var recordedWrites: [String] = []

    var writes: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedWrites
    }

    func read() -> String? { nil }

    func write(_ value: String) throws {
        lock.lock()
        recordedWrites.append(value)
        let shouldBlock = recordedWrites.count == 1
        lock.unlock()
        if shouldBlock {
            firstWriteGate.wait()
        }
    }

    func delete() throws {}

    func releaseFirstWrite() {
        firstWriteGate.signal()
    }
}
