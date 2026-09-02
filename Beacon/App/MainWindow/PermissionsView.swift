import SwiftUI

struct PermissionsView: View {
    @EnvironmentObject private var controller: BeaconController
    @Environment(\.scenePhase) private var scenePhase
    @State private var grantedPermissions = Set<PermissionKind>()

    var body: some View {
        Form {
            Section {
                ForEach(PermissionKind.allCases) { permission in
                    let isGranted = grantedPermissions.contains(permission)
                    HStack {
                        Image(systemName: isGranted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(isGranted ? .green : .orange)
                        VStack(alignment: .leading) {
                            Text(permission.rawValue)
                            Text(detail(permission)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !isGranted {
                            Button("Grant Access") {
                                controller.requestPermission(permission)
                                refreshPermissions()
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
        .formStyle(.grouped)
        .navigationTitle("Permissions")
        .onAppear(perform: refreshPermissions)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshPermissions() }
        }
    }

    private func detail(_ permission: PermissionKind) -> String {
        switch permission {
        case .accessibility: "Reads labels and positions of visible controls."
        case .screenRecording: "Creates the local privacy preview and visual fallback input."
        case .microphone: "Reserved for a later voice input feature."
        }
    }

    private func refreshPermissions() {
        let center = PermissionCenter()
        grantedPermissions = Set(PermissionKind.allCases.filter(center.isGranted))
    }
}
