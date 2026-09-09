import XCTest
@testable import Beacon

final class FloatingPromptLayoutTests: XCTestCase {
    @MainActor
    func testEachNewStatusStartsVisibleEvenWhenThePointerIsAlreadyOverIt() {
        let status = FloatingPromptPresentation(cursorMovementBaseline: 5, onSubmit: { _ in }, onCancel: {})
        XCTAssertFalse(status.allowsCursorFade(after: 6), "The interactive question never fades")
        for mode in [FloatingPromptPresentation.Mode.thinking, .waiting, .answer] {
            status.showStatus(mode: mode, message: "New message", cursorMovementBaseline: 10)
            XCTAssertFalse(status.allowsCursorFade(after: 10))
            XCTAssertTrue(status.allowsCursorFade(after: 11))
        }
        status.updateThinking(message: "Updated message", cursorMovementBaseline: 12)
        XCTAssertFalse(status.allowsCursorFade(after: 12))
        XCTAssertTrue(status.allowsCursorFade(after: 13))

        status.showStatus(mode: .completion, message: "Finished", cursorMovementBaseline: 20)
        XCTAssertFalse(status.allowsCursorFade(after: 21), "The interactive completion card never fades")
    }

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
        XCTAssertLessThanOrEqual(FloatingPromptLayout.completionSize.width, canvas.width)
        XCTAssertLessThanOrEqual(FloatingPromptLayout.completionSize.height, canvas.height)
    }
}
