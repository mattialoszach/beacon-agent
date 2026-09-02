import AppKit
import XCTest
@testable import Beacon

final class FloatingPromptFocusTests: XCTestCase {
    func testFocusResolverFindsEditableFieldAndSkipsLabels() {
        let root = NSView()
        let label = NSTextField(labelWithString: "Ask Beacon")
        let container = NSView()
        let input = NSTextField(string: "")
        root.addSubview(label)
        root.addSubview(container)
        container.addSubview(input)

        XCTAssertIdentical(PromptFocusResolver.editableTextField(in: root), input)
    }

    func testFocusResolverReturnsNilWithoutEditableField() {
        let root = NSView()
        root.addSubview(NSTextField(labelWithString: "Ask Beacon"))

        XCTAssertNil(PromptFocusResolver.editableTextField(in: root))
    }

    func testStatusPanelCanBePreventedFromTakingKeyFocus() {
        let panel = PromptPanel(
            contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        XCTAssertTrue(panel.canBecomeKey)
        panel.acceptsKeyEvents = false
        XCTAssertFalse(panel.canBecomeKey)
    }
}
