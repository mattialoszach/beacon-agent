import AppKit
import SwiftUI

private enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case home = "Home"
    case history = "History"
    case privacy = "Privacy"
    case models = "Models"
    case permissions = "Permissions"
    case inspector = "Developer Inspector"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .home: "house"
        case .history: "clock.arrow.circlepath"
        case .privacy: "lock.shield"
        case .models: "cpu"
        case .permissions: "checkmark.shield"
        case .inspector: "viewfinder"
        }
    }
}

struct MainWindowView: View {
    @EnvironmentObject private var controller: BeaconController
    @EnvironmentObject private var appPreferences: AppPreferencesStore
    @State private var selection: AppSection? = .home

    private var visibleSections: [AppSection] {
        AppSection.allCases.filter { $0 != .inspector || appPreferences.showDeveloperInspector }
    }

    var body: some View {
        NavigationSplitView {
            List(visibleSections) { section in
                Button {
                    selection = section
                } label: {
                    Label(section.rawValue, systemImage: section.icon)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                        .background(
                            selection == section ? BeaconPalette.blueViolet : .clear,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(selection == section ? .white : .primary)
                .listRowBackground(Color.clear)
            }
            .listStyle(.sidebar)
            .navigationTitle("Beacon")
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
            .safeAreaInset(edge: .bottom) {
                StatusPill()
                    .environmentObject(controller)
                    .padding(10)
            }
        } detail: {
            switch selection ?? .home {
            case .home: HomeView()
            case .history: HistoryView()
            case .privacy: PrivacyView()
            case .models: ModelSettingsView()
            case .permissions: PermissionsView()
            case .inspector: DeveloperInspectorView()
            }
        }
        .alert("Beacon", isPresented: Binding(
            get: { controller.errorMessage != nil },
            set: { if !$0 { controller.dismissError() } }
        )) {
            Button("OK") { controller.dismissError() }
        } message: {
            Text(controller.errorMessage ?? "Unknown error")
        }
        .onChange(of: appPreferences.showDeveloperInspector) { _, isVisible in
            if !isVisible, selection == .inspector {
                selection = .home
            }
        }
    }
}

private struct StatusPill: View {
    @EnvironmentObject private var controller: BeaconController

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(controller.isObserving ? .orange : .green)
                .frame(width: 7, height: 7)
            Text(controller.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .allowsTightening(true)
                .help(controller.statusMessage)
            Spacer(minLength: 0)
        }
        .padding(9)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
    }
}

private struct HomeView: View {
    @EnvironmentObject private var controller: BeaconController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "scope")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(BeaconPalette.blueViolet)
                    Text("Ask. See. Do.")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    Text("Beacon finds real controls in the app you're using and points you to the next step. You stay in control.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 650, alignment: .leading)
                }

                Button { controller.showPrompt() } label: {
                    Label("Ask Beacon", systemImage: "arrow.right.circle.fill")
                        .frame(minWidth: 130)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                HStack(spacing: 14) {
                    FeatureCard(icon: "keyboard", title: "Option + Space", detail: "Open Beacon beside your pointer from anywhere.")
                    FeatureCard(icon: "cursorarrow.rays", title: "Native guidance", detail: "Highlights are click-through and dismiss with Escape.")
                    FeatureCard(icon: "lock.shield", title: "Private by design", detail: "Accessibility matching runs on your Mac by default.")
                }

                if let response = controller.currentResponse {
                    GroupBox("Latest response") {
                        VStack(alignment: .leading, spacing: 9) {
                            Text(controller.currentQuestion ?? "")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(response.message).font(.title3.weight(.semibold))
                            if let target = controller.selectedTarget {
                                Text("\(controller.groundingStrategy) · \(Int((controller.groundingConfidence ?? 0) * 100))% confidence · \(String(describing: target))")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Home")
    }
}

private struct FeatureCard: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon).font(.title2).foregroundStyle(BeaconPalette.blueViolet)
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .padding(16)
        .background(.quaternary.opacity(0.42), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct HistoryView: View {
    @EnvironmentObject private var controller: BeaconController

    var body: some View {
        Group {
            if controller.history.isEmpty {
                ContentUnavailableView(
                    "No activity yet",
                    systemImage: "arrow.triangle.branch",
                    description: Text("Press Option + Space to ask Beacon for guidance.")
                )
            } else {
                List(controller.history) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(item.question).font(.headline)
                            Spacer()
                            if let succeeded = item.succeeded {
                                Image(systemName: succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(succeeded ? .green : .red)
                            }
                        }
                        Text(item.answer)
                        Text("\(item.applicationName) · \(item.date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 5)
                }
            }
        }
        .navigationTitle("History")
    }
}

struct SettingsView: View {
    @EnvironmentObject private var controller: BeaconController
    @EnvironmentObject private var appPreferences: AppPreferencesStore

    var body: some View {
        TabView {
            ModelSettingsView().tabItem { Label("Models", systemImage: "cpu") }
            PrivacyView().tabItem { Label("Privacy", systemImage: "lock.shield") }
            PermissionsView().tabItem { Label("Permissions", systemImage: "checkmark.shield") }
        }
        .environmentObject(controller)
        .environmentObject(appPreferences)
        .padding()
    }
}
