import Foundation
import Security

enum ModelProviderChoice: String, CaseIterable, Identifiable {
    case accessibility = "Accessibility matcher"
    case apple = "Apple Intelligence"
    case openAI = "OpenAI"

    var id: String { rawValue }
}

enum OpenAIModelChoice: String, CaseIterable, Identifiable {
    case terra = "gpt-5.6-terra"
    case luna = "gpt-5.6-luna"
    case sol = "gpt-5.6-sol"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .terra: "GPT-5.6 Terra"
        case .luna: "GPT-5.6 Luna"
        case .sol: "GPT-5.6 Sol"
        }
    }

    var summary: String {
        switch self {
        case .terra: "Recommended balance of instruction quality, speed, and cost."
        case .luna: "Faster, lower-cost reasoning for straightforward guidance."
        case .sol: "Highest-quality reasoning for complex interfaces and requests."
        }
    }
}

@MainActor
final class ModelConfigurationStore: ObservableObject {
    @Published var provider: ModelProviderChoice {
        didSet { defaults.set(provider.rawValue, forKey: Keys.provider) }
    }
    @Published var openAIModel: OpenAIModelChoice {
        didSet { defaults.set(openAIModel.rawValue, forKey: Keys.openAIModel) }
    }
    /// The editable draft shown in the API key field.
    @Published var apiKey: String = ""
    /// The credential actually persisted in Keychain. Requests use this so a half-typed
    /// or cleared draft never becomes the key that is sent.
    @Published private(set) var storedAPIKey = ""
    @Published private(set) var hasStoredAPIKey = false
    @Published private(set) var isLoadingAPIKey = false
    @Published private(set) var isMutatingAPIKey = false

    private let defaults: UserDefaults
    private let apiKeyStorage: any APIKeyStorage
    private var hasLoadedAPIKey = false
    private var apiKeyLoadTask: Task<String?, Never>?
    /// Serialises credential writes so a save and a remove cannot interleave and leave
    /// Keychain and the published state disagreeing.
    private var credentialOperation: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        apiKeyStorage: any APIKeyStorage = KeychainAPIKeyStorage(
            service: "org.beacon.agent",
            account: "openai-api-key"
        )
    ) {
        self.defaults = defaults
        self.apiKeyStorage = apiKeyStorage
        let savedProvider = ModelProviderChoice(rawValue: defaults.string(forKey: Keys.provider) ?? "") ?? .accessibility
        let usedLegacyLocalOnlyMode = defaults.string(forKey: Keys.legacyProcessingMode) == "Local Only"
        provider = savedProvider == .openAI && usedLegacyLocalOnlyMode ? .accessibility : savedProvider
        let savedOpenAIModel = defaults.string(forKey: Keys.openAIModel)
        openAIModel = savedOpenAIModel.flatMap(OpenAIModelChoice.init(rawValue:)) ?? .terra
        // Processing modes other than Local Only never affected routing. Cloud consent is
        // now represented by the single privacy setting, so remove the obsolete value.
        defaults.removeObject(forKey: Keys.legacyProcessingMode)
        if provider != savedProvider {
            defaults.set(provider.rawValue, forKey: Keys.provider)
        }
        if savedOpenAIModel != openAIModel.rawValue {
            defaults.set(openAIModel.rawValue, forKey: Keys.openAIModel)
        }
    }

    func loadAPIKeyIfNeeded() async {
        guard !hasLoadedAPIKey else { return }
        let task: Task<String?, Never>
        if let apiKeyLoadTask {
            task = apiKeyLoadTask
        } else {
            let storage = apiKeyStorage
            let newTask = Task.detached(priority: .utility) { storage.read() }
            apiKeyLoadTask = newTask
            isLoadingAPIKey = true
            task = newTask
        }
        let storedKey = await task.value ?? ""
        if apiKey.isEmpty {
            apiKey = storedKey
        }
        storedAPIKey = storedKey
        hasStoredAPIKey = !storedKey.isEmpty
        hasLoadedAPIKey = true
        isLoadingAPIKey = false
        apiKeyLoadTask = nil
    }

    func saveAPIKey() async throws {
        await loadAPIKeyIfNeeded()
        // Snapshot the submitted draft before waiting behind an earlier Keychain mutation.
        // The previous operation may finish by updating the visible field, but it must not
        // change what this already-requested save writes.
        let submittedDraft = apiKey
        let trimmedAPIKey = submittedDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        try await performCredentialOperation { [apiKeyStorage] in
            try await Task.detached(priority: .userInitiated) {
                try apiKeyStorage.write(trimmedAPIKey)
            }.value
            if self.apiKey == submittedDraft {
                self.apiKey = trimmedAPIKey
            }
            self.storedAPIKey = trimmedAPIKey
            self.hasStoredAPIKey = !trimmedAPIKey.isEmpty
        }
    }

    func removeAPIKey() async throws {
        await loadAPIKeyIfNeeded()
        let draftWhenRequested = apiKey
        try await performCredentialOperation { [apiKeyStorage] in
            try await Task.detached(priority: .userInitiated) {
                try apiKeyStorage.delete()
            }.value
            if self.apiKey == draftWhenRequested {
                self.apiKey = ""
            }
            self.storedAPIKey = ""
            self.hasStoredAPIKey = false
        }
    }

    /// Runs credential writes one at a time, in the order they were requested.
    private func performCredentialOperation(
        _ body: @escaping @MainActor () async throws -> Void
    ) async throws {
        let previous = credentialOperation
        var thrown: Error?
        let operation = Task { @MainActor in
            await previous?.value
            await self.loadAPIKeyIfNeeded()
            self.isMutatingAPIKey = true
            defer { self.isMutatingAPIKey = false }
            do { try await body() } catch { thrown = error }
        }
        credentialOperation = operation
        await operation.value
        if credentialOperation == operation { credentialOperation = nil }
        if let thrown { throw thrown }
    }

    private enum Keys {
        static let provider = "models.provider"
        static let legacyProcessingMode = "models.processingMode"
        static let openAIModel = "models.openAIModel"
    }
}

protocol APIKeyStorage: Sendable {
    func read() -> String?
    func write(_ value: String) throws
    func delete() throws
}

enum KeychainError: LocalizedError, Equatable {
    case status(OSStatus)

    var errorDescription: String? {
        guard case let .status(status) = self else { return nil }
        let reason = SecCopyErrorMessageString(status, nil) as String?
            ?? "Keychain error \(status)"
        switch status {
        case errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled:
            return "\(reason) Allow Beacon when macOS asks for Keychain access, or remove the “Beacon” item in Keychain Access and save the key again."
        default:
            return reason
        }
    }
}

struct KeychainAPIKeyStorage: APIKeyStorage {
    let service: String
    let account: String

    func read() -> String? {
        try? readStoredValue()
    }

    /// Distinguishes "no key stored" (nil) from a Keychain failure (throws), so a denied
    /// access prompt is not reported to the user as an absent key.
    func readStoredValue() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        guard let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ value: String) throws {
        guard !value.isEmpty else { return try delete() }
        let data = Data(value.utf8)
        // Update in place so a failure cannot leave the item deleted and unreplaced.
        let updateStatus = SecItemUpdate(
            keychainQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.status(updateStatus)
        }
        var item = keychainQuery
        item[kSecValueData as String] = data
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.status(status)
        }
    }

    func delete() throws {
        let status = SecItemDelete(keychainQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
    }

    private var keychainQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
