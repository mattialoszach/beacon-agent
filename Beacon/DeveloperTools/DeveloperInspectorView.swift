import AppKit
import SwiftUI

struct DeveloperInspectorView: View {
    @EnvironmentObject private var controller: BeaconController
    @State private var selectedElementID: String?
    @State private var showSetOfMarks = false
    @State private var candidateSource = CandidateSource.accessibility

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
                Button {
                    Task {
                        await controller.rebuildSetOfMarksPreview()
                        showSetOfMarks = true
                    }
                } label: {
                    Label("Set of Marks", systemImage: "number.square")
                }
                .disabled(controller.currentScene?.screenshot == nil)
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
                        GroupBox(showSetOfMarks ? "Set of Marks preview" : "Local redacted screenshot") {
                            let selectedSnapshot = showSetOfMarks
                                ? controller.setOfMarksPreview?.snapshot
                                : scene.screenshot
                            if let snapshot = selectedSnapshot {
                                ScreenSnapshotImageView(
                                    snapshot: snapshot,
                                    variant: showSetOfMarks ? "inspector-marks" : "inspector-redacted",
                                    maximumHeight: 270
                                )
                                HStack {
                                    if showSetOfMarks {
                                        Label("\(controller.setOfMarksPreview?.marks.count ?? 0) numbered candidates", systemImage: "number.square")
                                    } else {
                                        Label("\(snapshot.redactionCount) regions hidden", systemImage: "eye.slash")
                                    }
                                    Spacer()
                                    Text("\(snapshot.pixelWidth) × \(snapshot.pixelHeight)")
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                Toggle("Show numbered candidate image", isOn: $showSetOfMarks)
                                    .toggleStyle(.switch)
                            } else {
                                ContentUnavailableView("No screenshot", systemImage: "lock.shield", description: Text("Grant Screen Recording access or check app exclusions."))
                                    .frame(height: 220)
                            }
                        }

                        GroupBox("Grounding") {
                            LabeledContent("Application", value: scene.activeApplication.name)
                            LabeledContent("Window", value: scene.activeWindow?.title ?? "—")
                            LabeledContent(
                                "Request mode",
                                value: controller.requestModeClassification.map {
                                    "\($0.mode.rawValue) (\(Int($0.confidence * 100))%)"
                                } ?? "—"
                            )
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

                        GroupBox("Exact text model context") {
                            ScrollView {
                                Text(controller.modelContextPreview.isEmpty ? "No model request yet." : controller.modelContextPreview)
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
                        Picker("Candidates", selection: $candidateSource) {
                            Text("Accessibility (\(scene.elements.count))").tag(CandidateSource.accessibility)
                            Text("Local Vision (\(scene.visualElements.count))").tag(CandidateSource.vision)
                        }
                        .pickerStyle(.segmented)
                        .padding()

                        if candidateSource == .accessibility {
                            List(scene.elements, selection: $selectedElementID) { element in
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(element.id).font(.caption.monospaced()).foregroundStyle(BeaconPalette.mediumPurple)
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
                        } else {
                            List(scene.visualElements) { element in
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(element.id).font(.caption.monospaced()).foregroundStyle(BeaconPalette.blueViolet)
                                        Text(element.kind.displayName.uppercased())
                                            .font(.caption2.bold())
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Text("\(Int(element.confidence * 100))%")
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(element.text).lineLimit(2)
                                    Text(String(format: "x %.4f  y %.4f  w %.4f  h %.4f", element.bounds.x, element.bounds.y, element.bounds.width, element.bounds.height))
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
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

private enum CandidateSource {
    case accessibility
    case vision
}
