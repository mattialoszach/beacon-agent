import SwiftUI

struct ModelSettingsView: View {
    @EnvironmentObject private var controller: BeaconController
    @State private var keyStatus = ""

    var body: some View {
        Form {
            Section("Routing") {
                Picker("Processing mode", selection: $controller.modelSettings.processingMode) {
                    ForEach(ProcessingMode.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Instructor", selection: $controller.modelSettings.provider) {
                    ForEach(ModelProviderChoice.allCases) { Text($0.rawValue).tag($0) }
                }
                Text("The Accessibility matcher is deterministic and fully local. Apple Intelligence is used on supported Macs. Cloud use must also be enabled under Privacy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if controller.modelSettings.provider == .openAI {
                Section("OpenAI") {
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
                    Text("Beacon sends the question and redacted, structured scene data only when cloud processing is enabled. The current provider adapter does not upload screenshots.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Models")
    }
}
