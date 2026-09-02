import Foundation
import XCTest
@testable import Beacon

final class SceneFreshnessValidatorTests: XCTestCase {
    private let validator = SceneFreshnessValidator()

    func testRefreshesBoundsForAnOtherwiseStableAccessibilityTarget() {
        let source = scene(elements: [element(id: "target", label: "Save", x: 0.1)])
        let latest = scene(elements: [element(id: "target", label: "Save", x: 0.4)])

        let result = validator.validate(
            source: source,
            latest: latest,
            target: .accessibilityElement(
                elementId: "target",
                bounds: NormalizedRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1)
            )
        )

        XCTAssertEqual(result, .valid(target: .accessibilityElement(
            elementId: "target",
            bounds: NormalizedRect(x: 0.4, y: 0.1, width: 0.1, height: 0.1)
        )))
    }

    func testRejectsAMenuTargetThatDisappeared() {
        let source = scene(elements: [element(id: "print", role: "AXMenuItem", label: "Print")])
        let latest = scene(elements: [])

        let result = validator.validate(
            source: source,
            latest: latest,
            target: .accessibilityElement(
                elementId: "print",
                bounds: NormalizedRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1)
            )
        )

        XCTAssertEqual(result, .stale(.menuClosed(label: "Print", application: "Fixture")))
    }

    func testRejectsAChangedInterfaceEvenWhenTargetStillExists() {
        let source = scene(elements: [element(id: "target", label: "Save")])
        let latest = scene(elements: [
            element(id: "target", label: "Save"),
            element(id: "new", label: "Unexpected")
        ])

        let result = validator.validate(
            source: source,
            latest: latest,
            target: .accessibilityElement(
                elementId: "target",
                bounds: NormalizedRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1)
            )
        )

        XCTAssertEqual(result, .stale(.interfaceChanged(application: "Fixture")))
    }

    func testRejectsAnApplicationChange() {
        let source = scene(elements: [element(id: "target", label: "Save")])
        let latest = scene(
            application: .init(name: "Other", bundleIdentifier: "other", processIdentifier: 2),
            elements: [element(id: "target", label: "Save")]
        )

        let result = validator.validate(
            source: source,
            latest: latest,
            target: .accessibilityElement(
                elementId: "target",
                bounds: NormalizedRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1)
            )
        )

        XCTAssertEqual(result, .stale(.applicationChanged(expectedApplication: "Fixture")))
    }

    private func scene(
        application: ApplicationDescriptor = .init(
            name: "Fixture",
            bundleIdentifier: "fixture",
            processIdentifier: 1
        ),
        elements: [UIElementDescriptor]
    ) -> ScreenScene {
        ScreenScene(
            timestamp: Date(),
            activeApplication: application,
            activeWindow: .init(title: "Document", bounds: nil),
            screenshot: nil,
            elements: elements,
            displays: []
        )
    }

    private func element(
        id: String,
        role: String = "AXButton",
        label: String,
        x: Double = 0.1
    ) -> UIElementDescriptor {
        UIElementDescriptor(
            id: id,
            role: role,
            subrole: nil,
            label: label,
            title: nil,
            value: nil,
            enabled: true,
            focused: false,
            bounds: NormalizedRect(x: x, y: 0.1, width: 0.1, height: 0.1)
        )
    }
}
