import XCTest
@testable import Beacon

final class FloatingPromptLayoutTests: XCTestCase {
    func testPromptKeepsOriginalPaddingWithACompactNaturalHeight() {
        XCTAssertEqual(FloatingPromptLayout.outerPadding, 16)
        XCTAssertEqual(FloatingPromptLayout.inputPadding, 12)
        XCTAssertEqual(FloatingPromptLayout.maximumQuestionLines, 3)
        XCTAssertEqual(FloatingPromptLayout.promptSize.height, 114)
    }

    func testThinkingSurfaceHasRoomForVisibleStatusText() {
        let frame = FloatingPromptLayout.surfaceFrame(isThinking: true)

        XCTAssertEqual(frame.size, CGSize(width: 380, height: 110))
        XCTAssertLessThan(frame.width, FloatingPromptLayout.promptSize.width)
        XCTAssertGreaterThan(frame.width, frame.height * 3)
    }

    func testThinkingSurfaceStaysCenteredWherePromptAppeared() {
        let prompt = FloatingPromptLayout.surfaceFrame(isThinking: false)
        let thinking = FloatingPromptLayout.surfaceFrame(isThinking: true)

        XCTAssertEqual(thinking.midY, prompt.midY)
        XCTAssertEqual(thinking.midX, prompt.midX)
    }

    func testBothSurfacesRemainInsidePanelCanvas() {
        let canvas = CGRect(origin: .zero, size: FloatingPromptLayout.panelSize)

        XCTAssertTrue(canvas.contains(FloatingPromptLayout.surfaceFrame(isThinking: false)))
        XCTAssertTrue(canvas.contains(FloatingPromptLayout.surfaceFrame(isThinking: true)))
    }
}
