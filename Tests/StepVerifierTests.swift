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
        let expected = ExpectedOutcome(type: .windowAppears, description: "Export dialog appears",
            element: ExpectedElement(labels: ["Format"], role: "AXButton"))

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
            applicationScope: .mayChange, windowTitle: "Destination", destinationBundleIdentifier: "test.destination"
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

    func testClosingAWindowDoesNotVerifyWindowAppearance() {
        let before = scene(title: "Document", labels: ["Save"])
        let after = ScreenScene(timestamp: Date(), activeApplication: before.activeApplication,
                                activeWindow: nil, screenshot: nil, elements: [], displays: [])
        XCTAssertFalse(StepVerifier().verify(
            expected: .init(type: .windowAppears, description: "Export opens"), before: before, after: after
        ).succeeded)
        XCTAssertFalse(StepVerifier().verify(
            expected: .init(type: .windowDisappears, description: "Document closes"), before: before, after: after
        ).succeeded)
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
        let expected = ExpectedOutcome(type: .visualChange, description: "Permission is enabled",
            element: ExpectedElement(labels: ["Permission"], role: "AXButton", value: "1"))

        XCTAssertTrue(StepVerifier().verify(expected: expected, before: before, after: after).succeeded)
        XCTAssertNotEqual(SceneFingerprint(scene: before), SceneFingerprint(scene: after),
                          "The observer must detect the change before invoking the verifier.")
    }

    func testOCRFusedLabelCanVerifyAnAppearingAccessibilityControl() {
        let app = ApplicationDescriptor(
            name: "System Settings",
            bundleIdentifier: "com.apple.systempreferences",
            processIdentifier: 1
        )
        let window = WindowDescriptor(title: "Appearance", bounds: nil, id: "settings")
        let open = UIElementDescriptor(
            id: "appearance", role: "AXRow", subrole: nil, label: "Appearance",
            title: nil, value: nil, enabled: true, focused: false,
            bounds: .init(x: 0.1, y: 0.1, width: 0.3, height: 0.08), windowID: "settings"
        )
        let dark = UIElementDescriptor(
            id: "dark", role: "AXRadioButton", subrole: nil, label: nil,
            title: nil, value: "0", enabled: true, focused: false,
            bounds: .init(x: 0.55, y: 0.2, width: 0.18, height: 0.08), windowID: "settings"
        )
        let before = ScreenScene(
            timestamp: Date(), activeApplication: app, activeWindow: window,
            screenshot: nil, elements: [open], displays: []
        )
        var after = ScreenScene(
            timestamp: Date(), activeApplication: app, activeWindow: window,
            screenshot: nil, elements: [open, dark], displays: []
        )
        after.visualElements = [
            VisualElementDescriptor(
                id: "ocr_dark", text: "Dark",
                bounds: .init(x: 0.58, y: 0.22, width: 0.08, height: 0.03),
                confidence: 0.95, kind: .text
            )
        ]

        let result = StepVerifier().verify(
            expected: ExpectedOutcome(
                type: .elementAppears,
                description: "The Dark choice appears.",
                element: ExpectedElement(labels: ["Dark"], role: "AXRadioButton")
            ),
            before: before,
            after: after
        )

        XCTAssertTrue(result.succeeded)
    }

    func testOCRFusedLabelCanVerifyAStableControlValueChange() {
        func scene(value: String) -> ScreenScene {
            let bounds = NormalizedRect(x: 0.55, y: 0.2, width: 0.18, height: 0.08)
            var result = ScreenScene(
                timestamp: Date(),
                activeApplication: .init(
                    name: "System Settings",
                    bundleIdentifier: "com.apple.systempreferences",
                    processIdentifier: 1
                ),
                activeWindow: .init(title: "Appearance", bounds: nil, id: "settings"),
                screenshot: nil,
                elements: [
                    UIElementDescriptor(
                        id: "dark", role: "AXRadioButton", subrole: nil, label: nil,
                        title: nil, value: value, enabled: true, focused: false,
                        bounds: bounds, windowID: "settings"
                    )
                ],
                displays: []
            )
            result.visualElements = [
                VisualElementDescriptor(
                    id: "ocr_dark", text: "Dark",
                    bounds: .init(x: 0.58, y: 0.22, width: 0.08, height: 0.03),
                    confidence: 0.95, kind: .text
                )
            ]
            return result
        }

        let result = StepVerifier().verify(
            expected: ExpectedOutcome(
                type: .visualChange,
                description: "Dark appearance is selected.",
                element: ExpectedElement(
                    labels: ["Dark"], role: "AXRadioButton", value: "1"
                )
            ),
            before: scene(value: "0"),
            after: scene(value: "1")
        )

        XCTAssertTrue(result.succeeded)
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
            activeWindow: .init(title: title, bounds: nil, id: "window_\(title)"),
            screenshot: nil,
            elements: labels.enumerated().map { index, label in
                UIElementDescriptor(
                    id: "e_\(index)", role: "AXButton", subrole: nil, label: label,
                    title: nil, value: values[label], enabled: true, focused: label == focusedLabel,
                    bounds: .init(x: 0.1, y: 0.1 + Double(index) * 0.1, width: 0.1, height: 0.05), windowID: "window_\(title)"
                )
            },
            displays: []
        )
    }
}
