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

@MainActor
final class EscapeRoutingTests: XCTestCase {
    /// Escape must cancel guidance when an ordinary Beacon window is key, but must be
    /// left to a sheet or dialog while one is up.
    func testOrdinaryWindowLetsEscapeCancelGuidance() {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.titled], backing: .buffered, defer: true
        )

        XCTAssertTrue(EscapeRouting.handlesEscape(from: window))
        XCTAssertTrue(EscapeRouting.handlesEscape(from: nil))
    }

    func testASheetKeepsItsOwnEscape() {
        let sheet = SheetWindow(
            contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled], backing: .buffered, defer: true
        )

        XCTAssertTrue(sheet.isSheet)
        XCTAssertFalse(
            EscapeRouting.handlesEscape(from: sheet),
            "The dialog owns Escape while it is up"
        )
    }

    func testAWindowPresentingASheetKeepsEscape() {
        let host = SheetHostWindow(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.titled], backing: .buffered, defer: true
        )
        host.presentedSheet = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled], backing: .buffered, defer: true
        )

        XCTAssertFalse(EscapeRouting.handlesEscape(from: host))
    }
}

/// AppKit attaches a sheet asynchronously, which a unit test cannot rely on, so these
/// stand in for the two window states the routing rule inspects.
private final class SheetWindow: NSWindow {
    override var isSheet: Bool { true }
}

private final class SheetHostWindow: NSWindow {
    var presentedSheet: NSWindow?
    override var attachedSheet: NSWindow? { presentedSheet }
}
