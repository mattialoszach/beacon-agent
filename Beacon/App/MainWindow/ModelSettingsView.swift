import SwiftUI

struct ModelSettingsView: View {
    @EnvironmentObject private var controller: BeaconController
    @EnvironmentObject private var appPreferences: AppPreferencesStore
    @State private var keyStatus = ""

    var body: some View {
        Form {
            Section("Instructor") {
                Picker("Model", selection: $controller.modelSettings.provider) {
                    ForEach(ModelProviderChoice.allCases) { Text($0.rawValue).tag($0) }
                }
                Text(providerDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if controller.modelSettings.provider == .openAI {
                Section("OpenAI") {
                    Toggle("Allow OpenAI text processing", isOn: $controller.privacySettings.cloudProcessingEnabled)
                    TextField("Model", text: $controller.modelSettings.openAIModel)
                    SecureField("API key", text: $controller.modelSettings.apiKey)
                    HStack {
                        Button("Save in Keychain") {
                            do {
                                try controller.modelSettings.saveAPIKey()
                                keyStatus = "Saved"
                            } catch { keyStatus = error.localizedDescription }
                        }
                        Text(keyStatus).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Beacon sends the question and bounded, privacy-filtered scene text only when this is enabled. Screenshots stay on your Mac. When disabled, Beacon uses the local Accessibility matcher.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Developer tools") {
                Toggle("Show Developer Inspector", isOn: $appPreferences.showDeveloperInspector)
                Text("Adds perception, model-context, and grounding diagnostics to the Beacon sidebar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Models")
    }

    private var providerDescription: String {
        switch controller.modelSettings.provider {
        case .accessibility:
            "Fast, deterministic matching that runs entirely on your Mac. This is the default."
        case .apple:
            "On-device language reasoning on supported Macs, with automatic fallback to Accessibility matching."
        case .openAI:
            "Optional cloud reasoning. It is used only after you separately allow OpenAI text processing."
        }
    }
}
