import SwiftUI

struct ModelSettingsView: View {
    @EnvironmentObject private var controller: BeaconController
    @EnvironmentObject private var appPreferences: AppPreferencesStore
    @State private var keyStatus = ""
    @State private var isConfirmingAPIKeyRemoval = false

    var body: some View {
        Form {
            Section("Instructor") {
                Picker("Provider", selection: $controller.modelSettings.provider) {
                    ForEach(ModelProviderChoice.allCases) { Text($0.rawValue).tag($0) }
                }
                Text(providerDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if controller.modelSettings.provider == .openAI {
                Section("OpenAI") {
                    Toggle("Allow OpenAI text processing", isOn: $controller.privacySettings.cloudProcessingEnabled)
                    Toggle(
                        "Send the redacted visual preview",
                        isOn: $controller.privacySettings.cloudVisionEnabled
                    )
                    .disabled(!controller.privacySettings.cloudProcessingEnabled)
                    Picker("Model", selection: $controller.modelSettings.openAIModel) {
                        ForEach(OpenAIModelChoice.allCases) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                    Text(controller.modelSettings.openAIModel.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("API key")
                            .font(.subheadline)
                        SecureField(
                            "API key",
                            text: $controller.modelSettings.apiKey,
                            prompt: Text("Paste your OpenAI API key")
                        )
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity)
                        .disabled(controller.modelSettings.isMutatingAPIKey)

                        HStack(spacing: 8) {
                            Button("Save in Keychain") {
                                Task {
                                    do {
                                        try await controller.modelSettings.saveAPIKey()
                                        keyStatus = "Saved"
                                    } catch { keyStatus = error.localizedDescription }
                                }
                            }
                            .disabled(
                                apiKeyDraftIsEmpty || controller.modelSettings.isLoadingAPIKey
                                    || controller.modelSettings.isMutatingAPIKey
                            )
                            Button(role: .destructive) {
                                isConfirmingAPIKeyRemoval = true
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                            .buttonStyle(.bordered)
                            .tint(.red)
                            .disabled(
                                !controller.modelSettings.hasStoredAPIKey
                                    || controller.modelSettings.isLoadingAPIKey
                                    || controller.modelSettings.isMutatingAPIKey
                            )
                            .help("Remove API key from Keychain")
                            .accessibilityLabel("Remove API key from Keychain")
                            Text(apiKeyStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(controller.privacySettings.cloudVisionEnabled
                        ? "OpenAI receives the bounded scene text and the exact redacted, numbered image shown under Privacy. Excluded applications never send an image."
                        : "Beacon sends bounded, privacy-filtered scene text only. Screenshots stay on your Mac. When cloud processing is disabled, Beacon uses the local Accessibility matcher.")
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
        .confirmationDialog(
            "Remove OpenAI API key?",
            isPresented: $isConfirmingAPIKeyRemoval,
            titleVisibility: .visible
        ) {
            Button("Delete from Keychain", role: .destructive) {
                Task {
                    do {
                        try await controller.modelSettings.removeAPIKey()
                        keyStatus = "Removed from Keychain"
                    } catch {
                        keyStatus = error.localizedDescription
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Beacon will delete the stored key from macOS Keychain. You can add another key later.")
        }
        .task { await controller.modelSettings.loadAPIKeyIfNeeded() }
    }

    private var apiKeyStatus: String {
        if controller.modelSettings.isLoadingAPIKey { return "Loading from Keychain…" }
        if controller.modelSettings.isMutatingAPIKey { return "Updating Keychain…" }
        if !keyStatus.isEmpty { return keyStatus }
        return controller.modelSettings.hasStoredAPIKey ? "Stored in Keychain" : "Not saved"
    }

    private var apiKeyDraftIsEmpty: Bool {
        controller.modelSettings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var providerDescription: String {
        switch controller.modelSettings.provider {
        case .accessibility:
            "Fast, deterministic matching that runs entirely on your Mac."
        case .apple:
            "The default: on-device language reasoning on supported Macs, with automatic fallback to Accessibility matching."
        case .openAI:
            "Optional cloud reasoning. It is used only after you separately allow OpenAI text processing."
        }
    }
}
