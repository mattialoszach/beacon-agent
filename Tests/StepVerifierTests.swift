import Foundation
import XCTest
@testable import Beacon

final class StepVerifierTests: XCTestCase {
    func testSwitchingApplicationsDoesNotVerifyTheStep() {
        let before = scene(title: "Document", labels: ["Export"], bundleIdentifier: "test.before")
        let after = scene(title: "Other", labels: ["Done"], bundleIdentifier: "test.after")

        let result = StepVerifier().verify(
            expected: ExpectedOutcome(type: .visualChange, description: "The document changes"),
            before: before,
            after: after,
            visualDifference: 1
        )

        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.explanation.contains("active application changed"))
    }

    func testWindowAppearanceAcceptsNewDialogControls() {
        let before = scene(title: "Document", labels: ["File", "Edit"])
        let after = scene(title: "Export", labels: ["Cancel", "Export", "Format"])
        let expected = ExpectedOutcome(type: .windowAppears, description: "Export dialog appears")

        XCTAssertTrue(StepVerifier().verify(expected: expected, before: before, after: after).succeeded)
    }

    func testWindowAppearanceAcceptsApplicationHandoff() {
        let before = scene(
            title: "Source",
            labels: ["Open destination"],
            bundleIdentifier: "test.source"
        )
        let after = scene(
            title: "Destination",
            labels: ["Result"],
            bundleIdentifier: "test.destination"
        )
        let expected = ExpectedOutcome(
            type: .windowAppears,
            description: "The destination window appears",
            applicationScope: .mayChange
        )

        XCTAssertTrue(StepVerifier().verify(expected: expected, before: before, after: after).succeeded)
    }

    func testWindowAppearanceRejectsUnrelatedApplicationHandoff() {
        let before = scene(
            title: "Source",
            labels: ["Open a window"],
            bundleIdentifier: "test.source"
        )
        let after = scene(
            title: "Other",
            labels: ["Unrelated content"],
            bundleIdentifier: "test.unrelated"
        )
        let expected = ExpectedOutcome(
            type: .windowAppears,
            description: "A window appears"
        )

        XCTAssertFalse(StepVerifier().verify(expected: expected, before: before, after: after).succeeded)
    }

    func testUnrelatedFocusChangeDoesNotSatisfyElementAppearance() {
        let before = scene(title: "Document", labels: ["File", "Edit"])
        let after = scene(title: "Document", labels: ["File", "Edit"])
        let expected = ExpectedOutcome(type: .elementAppears, description: "PDF option appears")

        XCTAssertFalse(StepVerifier().verify(expected: expected, before: before, after: after).succeeded)
    }

    func testFocusOnlyChangeDoesNotSatisfyVisualChange() {
        let before = scene(title: "Document", labels: ["Field", "Save"], focusedLabel: "Field")
        let after = scene(title: "Document", labels: ["Field", "Save"], focusedLabel: "Save")
        let expected = ExpectedOutcome(type: .visualChange, description: "The content changes")

        XCTAssertFalse(StepVerifier().verify(expected: expected, before: before, after: after).succeeded)
    }

    func testControlValueChangeSatisfiesVisualChange() {
        let before = scene(
            title: "Document",
            labels: ["Permission"],
            values: ["Permission": "0"]
        )
        let after = scene(
            title: "Document",
            labels: ["Permission"],
            values: ["Permission": "1"]
        )
        let expected = ExpectedOutcome(type: .visualChange, description: "Permission is enabled")

        XCTAssertTrue(StepVerifier().verify(expected: expected, before: before, after: after).succeeded)
    }

    private func scene(
        title: String,
        labels: [String],
        bundleIdentifier: String = "fixture",
        focusedLabel: String? = nil,
        values: [String: String] = [:]
    ) -> ScreenScene {
        ScreenScene(
            timestamp: Date(),
            activeApplication: .init(name: "Fixture", bundleIdentifier: bundleIdentifier, processIdentifier: 1),
            activeWindow: .init(title: title, bounds: nil),
            screenshot: nil,
            elements: labels.enumerated().map { index, label in
                UIElementDescriptor(
                    id: "e_\(index)", role: "AXButton", subrole: nil, label: label,
                    title: nil, value: values[label], enabled: true, focused: label == focusedLabel,
                    bounds: .init(x: 0.1, y: 0.1 + Double(index) * 0.1, width: 0.1, height: 0.05)
                )
            },
            displays: []
        )
    }
}
