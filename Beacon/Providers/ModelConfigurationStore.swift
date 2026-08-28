import Foundation
import Security

enum ModelProviderChoice: String, CaseIterable, Identifiable {
    case accessibility = "Accessibility matcher"
    case apple = "Apple Intelligence"
    case openAI = "OpenAI"

    var id: String { rawValue }
}

enum ProcessingMode: String, CaseIterable, Identifiable {
    case localOnly = "Local Only"
    case privacyFirst = "Privacy First"
    case balanced = "Balanced"
    case bestQuality = "Best Quality"

    var id: String { rawValue }
}

@MainActor
final class ModelConfigurationStore: ObservableObject {
    @Published var provider: ModelProviderChoice {
        didSet { defaults.set(provider.rawValue, forKey: Keys.provider) }
    }
    @Published var processingMode: ProcessingMode {
        didSet { defaults.set(processingMode.rawValue, forKey: Keys.processingMode) }
    }
    @Published var openAIModel: String {
        didSet { defaults.set(openAIModel, forKey: Keys.openAIModel) }
    }
    @Published var apiKey: String = ""

    private let defaults: UserDefaults
    private let keychain = KeychainStore(service: "org.beacon.agent")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        provider = ModelProviderChoice(rawValue: defaults.string(forKey: Keys.provider) ?? "") ?? .accessibility
        processingMode = ProcessingMode(rawValue: defaults.string(forKey: Keys.processingMode) ?? "") ?? .privacyFirst
        openAIModel = defaults.string(forKey: Keys.openAIModel) ?? "gpt-5-mini"
        apiKey = keychain.read(account: "openai-api-key") ?? ""
    }

    func saveAPIKey() throws {
        try keychain.write(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), account: "openai-api-key")
    }

    private enum Keys {
        static let provider = "models.provider"
        static let processingMode = "models.processingMode"
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
