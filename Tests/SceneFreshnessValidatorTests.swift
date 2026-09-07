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

        XCTAssertEqual(validator.contextStatus(source: source, latest: latest), .valid)
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

    func testSameTitleDifferentWindowsAreNotInterchangeable() {
        let source = scene(windowID: "first", elements: [])
        let latest = scene(windowID: "second", elements: [])
        XCTAssertEqual(
            validator.contextStatus(source: source, latest: latest),
            .stale(.windowChanged(expectedWindow: "Document", application: "Fixture"))
        )
    }

    func testUnknownWindowIdentityFailsClosed() {
        let source = scene(windowID: nil, elements: [])
        XCTAssertEqual(
            validator.contextStatus(source: source, latest: source),
            .stale(.windowChanged(expectedWindow: "Document", application: "Fixture"))
        )
    }

    func testVisualTargetIsInvalidatedWhenWindowMoves() {
        let rect = NormalizedRect(x: 0, y: 0, width: 0.5, height: 0.5)
        let source = scene(bounds: rect, elements: [])
        let latest = scene(bounds: .init(x: 0.3, y: 0, width: 0.5, height: 0.5), elements: [])
        XCTAssertEqual(validator.validate(source: source, latest: latest, target: .visualRegion(bounds: rect)),
                       .stale(.visualContextUnavailable(application: "Fixture")))
    }

    func testResolutionAndScaleChangesInvalidateSceneEvenWithSameNormalizedBounds() {
        let bounds = NormalizedRect(x: 0, y: 0, width: 1, height: 1)
        let original = DisplayDescriptor(id: 1, bounds: bounds, scaleFactor: 2, logicalSize: CGSize(width: 1440, height: 900))
        for replacement in [
            DisplayDescriptor(id: 1, bounds: bounds, scaleFactor: 1, logicalSize: original.logicalSize),
            DisplayDescriptor(id: 1, bounds: bounds, scaleFactor: 2, logicalSize: CGSize(width: 1280, height: 800)),
            DisplayDescriptor(id: 2, bounds: bounds, scaleFactor: 2, logicalSize: original.logicalSize)
        ] {
            XCTAssertEqual(
                validator.contextStatus(
                    source: scene(displays: [original], elements: []),
                    latest: scene(displays: [replacement], elements: [])
                ),
                .stale(.displaysChanged)
            )
        }
    }

    private func scene(
        application: ApplicationDescriptor = .init(
            name: "Fixture",
            bundleIdentifier: "fixture",
            processIdentifier: 1
        ),
        windowID: String? = "document",
        bounds: NormalizedRect? = nil,
        displays: [DisplayDescriptor] = [],
        elements: [UIElementDescriptor]
    ) -> ScreenScene {
        ScreenScene(
            timestamp: Date(),
            activeApplication: application,
            activeWindow: .init(title: "Document", bounds: bounds, id: windowID),
            screenshot: nil,
            elements: elements,
            displays: displays
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

final class TruncatedCaptureFreshnessTests: XCTestCase {
    private let validator = SceneFreshnessValidator()

    /// The Accessibility walk stops at a time and node budget, so a busy application can
    /// return far fewer elements for either a changed or unchanged interface. Neither can
    /// be proved from an incomplete view.
    func testTruncatedCaptureIsInconclusive() {
        let source = scene(elementCount: 40, truncated: false)
        let truncated = scene(elementCount: 8, truncated: true)

        XCTAssertEqual(validator.contextStatus(source: source, latest: truncated), .inconclusive)
    }

    func testACompleteCaptureWithTheSameShrinkageIsStillStale() {
        let source = scene(elementCount: 40, truncated: false)
        let complete = scene(elementCount: 8, truncated: false)

        XCTAssertEqual(
            validator.contextStatus(source: source, latest: complete),
            .stale(.interfaceChanged(application: "App"))
        )
    }

    func testTruncationValidatesASurvivingStableAccessibilityTarget() {
        let source = scene(elementCount: 40, truncated: false)
        let truncated = scene(elementCount: 8, truncated: true)
        let target = GroundedTarget.accessibilityElement(
            elementId: "e_3", bounds: .init(x: 0.1, y: 0.1, width: 0.05, height: 0.02)
        )

        XCTAssertEqual(
            validator.validate(source: source, latest: truncated, target: target),
            .valid(target: target)
        )
    }

    func testTruncationRemainsInconclusiveForAVisualTarget() {
        let source = scene(elementCount: 40, truncated: false)
        let truncated = scene(elementCount: 8, truncated: true)

        XCTAssertEqual(
            validator.validate(
                source: source,
                latest: truncated,
                target: .visualRegion(bounds: .init(x: 0.1, y: 0.1, width: 0.05, height: 0.02))
            ),
            .inconclusive
        )
    }

    func testTruncationDoesNotHideAMissingTarget() {
        let source = scene(elementCount: 40, truncated: false)
        let truncated = scene(elementCount: 8, truncated: true)
        let target = GroundedTarget.accessibilityElement(
            elementId: "e_30", bounds: .init(x: 0.1, y: 0.1, width: 0.05, height: 0.02)
        )

        guard case let .stale(issue) = validator.validate(
            source: source, latest: truncated, target: target
        ) else {
            return XCTFail("A target missing from the latest capture must still be stale")
        }
        XCTAssertEqual(issue, .targetUnavailable(label: "Control 30", application: "App"))
    }

    private func scene(elementCount: Int, truncated: Bool) -> ScreenScene {
        ScreenScene(
            timestamp: Date(),
            activeApplication: .init(name: "App", bundleIdentifier: "com.example.app", processIdentifier: 5),
            activeWindow: .init(title: "Main", bounds: nil, id: "w1"),
            screenshot: nil,
            elements: (0..<elementCount).map { index in
                UIElementDescriptor(
                    id: "e_\(index)", role: "AXButton", subrole: nil, label: "Control \(index)",
                    title: nil, value: nil, enabled: true, focused: false,
                    bounds: .init(x: 0.1, y: 0.1, width: 0.05, height: 0.02), windowID: "w1"
                )
            },
            displays: [],
            isTruncated: truncated
        )
    }
}
