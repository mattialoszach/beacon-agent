import Foundation
import Security

enum ModelProviderChoice: String, CaseIterable, Identifiable {
    case accessibility = "Accessibility matcher"
    case apple = "Apple Intelligence"
    case openAI = "OpenAI"

    var id: String { rawValue }
}

@MainActor
final class ModelConfigurationStore: ObservableObject {
    @Published var provider: ModelProviderChoice {
        didSet { defaults.set(provider.rawValue, forKey: Keys.provider) }
    }
    @Published var openAIModel: String {
        didSet { defaults.set(openAIModel, forKey: Keys.openAIModel) }
    }
    @Published var apiKey: String = ""
    @Published private(set) var hasStoredAPIKey = false

    private let defaults: UserDefaults
    private let apiKeyStorage: any APIKeyStorage

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
        openAIModel = defaults.string(forKey: Keys.openAIModel) ?? "gpt-5-mini"
        apiKey = apiKeyStorage.read() ?? ""
        hasStoredAPIKey = !apiKey.isEmpty

        // Processing modes other than Local Only never affected routing. Cloud consent is
        // now represented by the single privacy setting, so remove the obsolete value.
        defaults.removeObject(forKey: Keys.legacyProcessingMode)
        if provider != savedProvider {
            defaults.set(provider.rawValue, forKey: Keys.provider)
        }
    }

    func saveAPIKey() throws {
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        try apiKeyStorage.write(trimmedAPIKey)
        apiKey = trimmedAPIKey
        hasStoredAPIKey = !trimmedAPIKey.isEmpty
    }

    func removeAPIKey() throws {
        try apiKeyStorage.delete()
        apiKey = ""
        hasStoredAPIKey = false
    }

    private enum Keys {
        static let provider = "models.provider"
        static let legacyProcessingMode = "models.processingMode"
        static let openAIModel = "models.openAIModel"
    }
}

protocol APIKeyStorage {
    func read() -> String?
    func write(_ value: String) throws
    func delete() throws
}

struct KeychainAPIKeyStorage: APIKeyStorage {
    let service: String
    let account: String

    func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ value: String) throws {
        let base = keychainQuery
        try delete()
        guard !value.isEmpty else { return }
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    func delete() throws {
        let status = SecItemDelete(keychainQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
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
