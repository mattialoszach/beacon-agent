import AppKit
import SwiftUI

@MainActor
final class FloatingPromptController {
    private var panel: PromptPanel?

    func show(
        mode: InteractionMode,
        onSubmit: @escaping (String, InteractionMode) -> Void,
        onCancel: @escaping () -> Void
    ) {
        close()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        let size = CGSize(width: 440, height: 142)
        let visible = screen?.visibleFrame ?? CGRect(origin: mouse, size: size)
        let origin = CGPoint(
            x: min(max(mouse.x - size.width / 2, visible.minX + 12), visible.maxX - size.width - 12),
            y: min(max(mouse.y - size.height - 18, visible.minY + 12), visible.maxY - size.height - 12)
        )
        let panel = PromptPanel(
            contentRect: CGRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = NSHostingView(rootView: FloatingPromptView(
            initialMode: mode,
            onSubmit: { [weak self] question, selectedMode in
                self?.close()
                onSubmit(question, selectedMode)
            },
            onCancel: { [weak self] in
                self?.close()
                onCancel()
            }
        ))
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private final class PromptPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct FloatingPromptView: View {
    let initialMode: InteractionMode
    let onSubmit: (String, InteractionMode) -> Void
    let onCancel: () -> Void

    @State private var question = ""
    @State private var mode: InteractionMode
    @FocusState private var focused: Bool

    init(
        initialMode: InteractionMode,
        onSubmit: @escaping (String, InteractionMode) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.initialMode = initialMode
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        _mode = State(initialValue: initialMode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Beacon", systemImage: "scope")
                    .font(.headline)
                Spacer()
                Picker("Mode", selection: $mode) {
                    Text("Ask").tag(InteractionMode.ask)
                    Text("Guide").tag(InteractionMode.guide)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 148)
            }

            HStack(spacing: 10) {
                TextField("What do you want to do?", text: $question)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($focused)
                    .onSubmit(submit)
                Button(action: submit) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                }
                .buttonStyle(.borderedProminent)
                .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)
            .background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

            Text("Return to ask  ·  Esc to dismiss  ·  Beacon never clicks for you")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.15)))
        .onAppear { focused = true }
        .onExitCommand(perform: onCancel)
    }

    private func submit() {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSubmit(trimmed, mode)
    }
}
