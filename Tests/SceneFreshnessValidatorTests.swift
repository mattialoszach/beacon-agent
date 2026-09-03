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

    func testAcceptsVolatileStateAndSmallAccessibilityTreeDifferences() {
        let stableElements = (0..<7).map { index in
            element(id: "stable_\(index)", label: "Control \(index)")
        }
        let source = scene(elements: [
            element(id: "target", label: "Save", value: "Idle")
        ] + stableElements)
        let latest = scene(elements: [
            element(id: "target", label: "Save", x: 0.4, value: "Active", focused: true)
        ] + stableElements + [element(id: "transient", label: "Status")])

        XCTAssertNil(validator.contextIssue(source: source, latest: latest))
        XCTAssertEqual(
            validator.validate(
                source: source,
                latest: latest,
                target: .accessibilityElement(
                    elementId: "target",
                    bounds: NormalizedRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1)
                )
            ),
            .valid(target: .accessibilityElement(
                elementId: "target",
                bounds: NormalizedRect(x: 0.4, y: 0.1, width: 0.1, height: 0.1)
            ))
        )
    }

    func testRejectsATargetThatBecameDisabled() {
        let source = scene(elements: [element(id: "target", label: "Save")])
        let latest = scene(elements: [element(id: "target", label: "Save", enabled: false)])

        let result = validator.validate(
            source: source,
            latest: latest,
            target: .accessibilityElement(
                elementId: "target",
                bounds: NormalizedRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1)
            )
        )

        XCTAssertEqual(result, .stale(.targetUnavailable(label: "Save", application: "Fixture")))
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
        x: Double = 0.1,
        value: String? = nil,
        enabled: Bool = true,
        focused: Bool = false
    ) -> UIElementDescriptor {
        UIElementDescriptor(
            id: id,
            role: role,
            subrole: nil,
            label: label,
            title: nil,
            value: value,
            enabled: enabled,
            focused: focused,
            bounds: NormalizedRect(x: x, y: 0.1, width: 0.1, height: 0.1)
        )
    }
}
