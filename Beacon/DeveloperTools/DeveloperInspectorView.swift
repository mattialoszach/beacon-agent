import AppKit
import SwiftUI

struct DeveloperInspectorView: View {
    @EnvironmentObject private var controller: BeaconController
    @State private var selectedElementID: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { Task { await controller.refreshInspector() } } label: {
                    Label("Capture Scene", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                Button { controller.showAllElementsOverlay() } label: {
                    Label("Draw All Elements", systemImage: "viewfinder")
                }
                .disabled(controller.currentScene?.elements.isEmpty != false)
                Button("Dismiss Overlay") { controller.dismissOverlay() }
                Spacer()
                if let scene = controller.currentScene {
                    Text("\(scene.elements.count) elements")
                        .foregroundStyle(.secondary)
                }
            }
            .padding()

            Divider()

            if let scene = controller.currentScene {
                HSplitView {
                    VStack(alignment: .leading, spacing: 10) {
                        GroupBox("What the model sees") {
                            if let snapshot = scene.screenshot,
                               let image = NSImage(data: snapshot.pngData) {
                                Image(nsImage: image)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxWidth: .infinity, maxHeight: 270)
                                HStack {
                                    Label("\(snapshot.redactionCount) regions hidden", systemImage: "eye.slash")
                                    Spacer()
                                    Text("\(snapshot.pixelWidth) × \(snapshot.pixelHeight)")
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            } else {
                                ContentUnavailableView("No screenshot", systemImage: "lock.shield", description: Text("Grant Screen Recording access or check app exclusions."))
                                    .frame(height: 220)
                            }
                        }

                        GroupBox("Grounding") {
                            LabeledContent("Application", value: scene.activeApplication.name)
                            LabeledContent("Window", value: scene.activeWindow?.title ?? "—")
                            LabeledContent("Strategy", value: controller.groundingStrategy)
                            LabeledContent("Confidence", value: controller.groundingConfidence.map { "\(Int($0 * 100))%" } ?? "—")
                        }

                        GroupBox("Normalized model response") {
                            ScrollView {
                                Text(controller.rawModelResponse.isEmpty ? "No model response yet." : controller.rawModelResponse)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(minHeight: 100)
                        }
                    }
                    .padding()
                    .frame(minWidth: 360)

                    VStack(alignment: .leading, spacing: 0) {
                        Text("Accessibility elements")
                            .font(.headline)
                            .padding()
                        List(scene.elements, selection: $selectedElementID) { element in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(element.id).font(.caption.monospaced()).foregroundStyle(Color.accentColor)
                                    Text(element.role ?? "Unknown role").font(.caption.monospaced())
                                    if element.focused { Text("FOCUSED").font(.caption2.bold()).foregroundStyle(.yellow) }
                                }
                                Text(element.bestLabel).lineLimit(2)
                                if let bounds = element.bounds {
                                    Text(String(format: "x %.4f  y %.4f  w %.4f  h %.4f", bounds.x, bounds.y, bounds.width, bounds.height))
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .tag(element.id)
                        }
                    }
                    .frame(minWidth: 350)
                }
            } else {
                ContentUnavailableView(
                    "No scene captured",
                    systemImage: "viewfinder",
                    description: Text("Capture a scene to inspect accessibility geometry and the privacy-filtered screenshot.")
                )
            }
        }
        .navigationTitle("Developer Inspector")
    }
}
