#if canImport(FoundationModels)
import Foundation
import FoundationModels
import XCTest
@testable import Beacon

final class AppleFoundationModelIntegrationTests: XCTestCase {
    func testLargeSceneDoesNotOverflowLocalModelContext() async throws {
        guard ProcessInfo.processInfo.environment["BEACON_RUN_MODEL_TESTS"] == "1" else {
            throw XCTSkip("Set BEACON_RUN_MODEL_TESTS=1 to exercise the on-device model.")
        }
        guard #available(macOS 26.0, *), SystemLanguageModel.default.availability == .available else {
            throw XCTSkip("Apple Foundation Model is unavailable on this Mac.")
        }

        var elements = (0..<800).map { index in
            UIElementDescriptor(
                id: "e_\(index)", role: "AXButton", subrole: nil,
                label: "Generic control \(index)", title: nil, value: nil,
                enabled: true, focused: false,
                bounds: .init(x: 0.1, y: 0.1, width: 0.1, height: 0.04)
            )
        }
        elements.append(UIElementDescriptor(
            id: "e_export", role: "AXButton", subrole: nil,
            label: "Export", title: nil, value: nil,
            enabled: true, focused: false,
            bounds: .init(x: 0.7, y: 0.7, width: 0.1, height: 0.05)
        ))
        let scene = ScreenScene(
            timestamp: Date(),
            activeApplication: .init(name: "Fixture", bundleIdentifier: "fixture", processIdentifier: 1),
            activeWindow: .init(title: "Document", bounds: .init(x: 0, y: 0, width: 1, height: 1)),
            screenshot: nil,
            elements: elements,
            displays: []
        )
        let response = try await AppleFoundationModelProvider().reason(request: InstructorRequest(
            question: "How do I export this?",
            scene: scene,
            mode: .guide
        ))

        XCTAssertFalse(response.message.isEmpty)
    }
}
#endif
