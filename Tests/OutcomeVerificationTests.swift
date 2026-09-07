import XCTest
@testable import Beacon

final class OutcomeVerificationTests: XCTestCase {
    private let verifier = StepVerifier()
    private let bounds = NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1)

    func testOnlyTheExpectedElementAppearanceAdvances() {
        let expected = ExpectedOutcome(type: .elementAppears, description: "PDF appears",
            element: ExpectedElement(labels: ["PDF"], role: "AXMenuItem"))
        let before = scene([])
        XCTAssertFalse(verifier.verify(expected: expected, before: before, after: scene([control("Cancel")])).succeeded)
        XCTAssertTrue(verifier.verify(expected: expected, before: before, after: scene([control("PDF", role: "AXMenuItem")])).succeeded)
        XCTAssertFalse(verifier.verify(expected: expected, before: before, after: scene([control("PDF")])).succeeded)
        XCTAssertFalse(verifier.verify(expected: expected, before: before, after: scene([control("PDF", role: "AXMenuItem", windowID: "other")])).succeeded)
    }

    func testDuplicateExpectedLabelsAreAmbiguous() {
        let expected = ExpectedOutcome(type: .elementAppears, description: "Save appears", element: ExpectedElement(labels: ["Save"]))
        XCTAssertFalse(verifier.verify(expected: expected, before: scene([]),
            after: scene([control("Save", id: "one"), control("Save", id: "two")])).succeeded)
    }

    func testUnrelatedValueChangesAndWrongExpectedValuesDoNotAdvance() {
        let expected = ExpectedOutcome(type: .visualChange, description: "PDF selected",
            element: ExpectedElement(id: "format", labels: ["Format"], value: "PDF"))
        let before = scene([control("Format", id: "format", value: "PNG"), control("Quality", value: "0")])
        XCTAssertFalse(verifier.verify(expected: expected, before: before,
            after: scene([control("Format", id: "format", value: "PNG"), control("Quality", value: "1")])).succeeded)
        XCTAssertFalse(verifier.verify(expected: expected, before: before,
            after: scene([control("Format", id: "format", value: "JPEG")])).succeeded)
        XCTAssertTrue(verifier.verify(expected: expected, before: before,
            after: scene([control("Format", id: "format", value: "PDF")])).succeeded)
    }

    func testValueOfNewOrReplacedControlDoesNotVerifyAChange() {
        let expected = ExpectedOutcome(type: .visualChange, description: "PDF selected",
            element: ExpectedElement(labels: ["Format"], value: "PDF"))
        XCTAssertFalse(verifier.verify(expected: expected, before: scene([control("Format", id: "old", value: "PNG")]),
            after: scene([control("Format", id: "new", value: "PDF")])).succeeded)
    }

    func testOnlyExpectedFocusAdvances() {
        let expected = ExpectedOutcome(type: .focusedElementChanges, description: "Name focused",
            element: ExpectedElement(labels: ["Name"]))
        let before = scene([control("Name"), control("Cancel")])
        XCTAssertFalse(verifier.verify(expected: expected, before: before,
            after: scene([control("Name"), control("Cancel", focused: true)])).succeeded)
        XCTAssertTrue(verifier.verify(expected: expected, before: before,
            after: scene([control("Name", focused: true), control("Cancel")])).succeeded)
    }

    func testSameTitleWindowSwitchDoesNotVerifyElementAppearance() {
        let expected = ExpectedOutcome(type: .elementAppears, description: "Save appears", element: ExpectedElement(labels: ["Save"]))
        XCTAssertFalse(verifier.verify(expected: expected, before: scene([]),
            after: scene([control("Save", windowID: "other")], windowID: "other")).succeeded)
    }

    func testWindowAppearanceNeedsANewWindowWithSpecificEvidence() {
        let expected = ExpectedOutcome(type: .windowAppears, description: "Export sheet opens",
            element: ExpectedElement(labels: ["Save"], role: "AXButton"))
        let before = scene([])
        XCTAssertFalse(verifier.verify(expected: expected, before: before, after: scene([control("Save")])).succeeded)
        XCTAssertFalse(verifier.verify(expected: expected, before: before,
            after: scene([control("Cancel", windowID: "dialog")], windowID: "dialog")).succeeded)
        var after = scene([control("Save", windowID: "sheet")])
        after.windows = [.init(title: nil, bounds: bounds, id: "sheet", role: "AXSheet", parentWindowID: "document")]
        XCTAssertTrue(verifier.verify(expected: expected, before: before, after: after).succeeded)
        after.windows = [.init(title: nil, bounds: bounds, id: "sheet", role: "AXSheet", parentWindowID: "unrelated")]
        XCTAssertFalse(verifier.verify(expected: expected, before: before, after: after).succeeded)
    }

    func testSaveAndCancelClosureBothRequireUserConfirmation() {
        let expected = ExpectedOutcome(type: .windowDisappears, description: "Export saved")
        XCTAssertFalse(expected.canVerifyAutomatically)
        let before = scene([control("Save", windowID: "sheet"), control("Cancel", windowID: "sheet")], windowID: "sheet")
        XCTAssertFalse(verifier.verify(expected: expected, before: before, after: scene([])).succeeded)
    }

    func testWholeFrameDifferenceNeverProvesSuccess() {
        for type in [ExpectedOutcomeType.visualChange, .elementAppears, .windowAppears] {
            let expected = ExpectedOutcome(type: type, description: "It changes")
            XCTAssertFalse(verifier.verify(expected: expected, before: scene([]), after: scene([control("Anything")]), visualDifference: 1).succeeded)
        }
    }

    func testDestinationApplicationMustMatchExactly() {
        let expected = ExpectedOutcome(type: .windowAppears, description: "Destination opens",
            applicationScope: .mayChange, windowTitle: "Document", destinationBundleIdentifier: "expected.app")
        XCTAssertFalse(verifier.verify(expected: expected, before: scene([]),
            after: scene([], windowID: "other", bundleID: "unrelated.app")).succeeded)
        XCTAssertTrue(verifier.verify(expected: expected, before: scene([]),
            after: scene([], windowID: "other", bundleID: "expected.app")).succeeded)
    }

    func testDisplayDisconnectDoesNotAdvance() {
        let expected = ExpectedOutcome(type: .elementAppears, description: "Save appears", element: ExpectedElement(labels: ["Save"]))
        var before = scene([])
        before = ScreenScene(timestamp: before.timestamp, activeApplication: before.activeApplication,
            activeWindow: before.activeWindow, screenshot: nil, elements: [],
            displays: [.init(id: 1, bounds: bounds, scaleFactor: 2)])
        XCTAssertFalse(verifier.verify(expected: expected, before: before, after: scene([control("Save")])).succeeded)
    }

    private func scene(_ elements: [UIElementDescriptor], windowID: String = "document", bundleID: String = "fixture") -> ScreenScene {
        ScreenScene(timestamp: Date(), activeApplication: .init(name: "Fixture", bundleIdentifier: bundleID, processIdentifier: 1),
            activeWindow: .init(title: "Document", bounds: bounds, id: windowID), screenshot: nil, elements: elements, displays: [])
    }

    private func control(_ label: String, id: String? = nil, role: String = "AXButton", value: String? = nil,
                         focused: Bool = false, windowID: String = "document") -> UIElementDescriptor {
        UIElementDescriptor(id: id ?? label, role: role, subrole: nil, label: label, title: nil, value: value,
            enabled: true, focused: focused, bounds: bounds, windowID: windowID)
    }
}
