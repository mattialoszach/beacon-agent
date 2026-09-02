import XCTest
@testable import Beacon

final class FloatingPromptLayoutTests: XCTestCase {
    func testThinkingSurfaceHasRoomForVisibleStatusText() {
        let frame = FloatingPromptLayout.surfaceFrame(isThinking: true)

        XCTAssertEqual(frame.size, CGSize(width: 380, height: 110))
        XCTAssertLessThan(frame.width, FloatingPromptLayout.promptSize.width)
        XCTAssertGreaterThan(frame.width, frame.height * 3)
    }

    func testThinkingSurfaceMovesDownFromPrompt() {
        let prompt = FloatingPromptLayout.surfaceFrame(isThinking: false)
        let thinking = FloatingPromptLayout.surfaceFrame(isThinking: true)

        XCTAssertGreaterThan(thinking.midY, prompt.midY)
        XCTAssertEqual(thinking.midX, prompt.midX)
    }

    func testBothSurfacesRemainInsidePanelCanvas() {
        let canvas = CGRect(origin: .zero, size: FloatingPromptLayout.panelSize)

        XCTAssertTrue(canvas.contains(FloatingPromptLayout.surfaceFrame(isThinking: false)))
        XCTAssertTrue(canvas.contains(FloatingPromptLayout.surfaceFrame(isThinking: true)))
    }
}
