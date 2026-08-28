import SwiftUI

struct PermissionsView: View {
    @EnvironmentObject private var controller: BeaconController
    @State private var refreshID = UUID()

    var body: some View {
        Form {
            Section {
                ForEach(PermissionKind.allCases) { permission in
                    HStack {
                        Image(systemName: PermissionCenter().isGranted(permission) ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(PermissionCenter().isGranted(permission) ? .green : .orange)
                        VStack(alignment: .leading) {
                            Text(permission.rawValue)
                            Text(detail(permission)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !PermissionCenter().isGranted(permission) {
                            Button("Grant Access") {
                                controller.requestPermission(permission)
                                refreshID = UUID()
                            }
                        }
                    }
                    .padding(.vertical, 5)
                }
            } header: {
                Text("System permissions")
            } footer: {
                Text("Beacon only observes after an explicit shortcut or while verifying a visible guide step. It does not continuously record your screen.")
            }
        }
        .id(refreshID)
        .formStyle(.grouped)
        .navigationTitle("Permissions")
    }

    private func detail(_ permission: PermissionKind) -> String {
        switch permission {
        case .accessibility: "Reads labels and positions of visible controls."
        case .screenRecording: "Creates the local privacy preview and visual fallback input."
        case .microphone: "Reserved for a later voice input feature."
        }
    }
}
