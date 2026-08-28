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

    private let defaults: UserDefaults
    private let keychain = KeychainStore(service: "org.beacon.agent")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let savedProvider = ModelProviderChoice(rawValue: defaults.string(forKey: Keys.provider) ?? "") ?? .accessibility
        let usedLegacyLocalOnlyMode = defaults.string(forKey: Keys.legacyProcessingMode) == "Local Only"
        provider = savedProvider == .openAI && usedLegacyLocalOnlyMode ? .accessibility : savedProvider
        openAIModel = defaults.string(forKey: Keys.openAIModel) ?? "gpt-5-mini"
        apiKey = keychain.read(account: "openai-api-key") ?? ""

        // Processing modes other than Local Only never affected routing. Cloud consent is
        // now represented by the single privacy setting, so remove the obsolete value.
        defaults.removeObject(forKey: Keys.legacyProcessingMode)
        if provider != savedProvider {
            defaults.set(provider.rawValue, forKey: Keys.provider)
        }
    }

    func saveAPIKey() throws {
        try keychain.write(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), account: "openai-api-key")
    }

    private enum Keys {
        static let provider = "models.provider"
        static let legacyProcessingMode = "models.processingMode"
        static let openAIModel = "models.openAIModel"
    }
}

private struct KeychainStore {
    let service: String

    func read(account: String) -> String? {
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

    func write(_ value: String, account: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}
