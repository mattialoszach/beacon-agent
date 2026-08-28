import XCTest
@testable import Beacon

final class InstructorStateMachineTests: XCTestCase {
    func testGuideHappyPath() throws {
        var machine = InstructorStateMachine()
        XCTAssertEqual(try machine.handle(.questionReceived), .capturingScene)
        XCTAssertEqual(try machine.handle(.sceneCaptured), .understanding)
        XCTAssertEqual(try machine.handle(.responseGenerated(needsTarget: true)), .grounding)
        XCTAssertEqual(try machine.handle(.targetGrounded), .presenting)
        XCTAssertEqual(try machine.handle(.instructionPresented(expectsChange: true)), .waitingForChange)
        XCTAssertEqual(try machine.handle(.meaningfulChangeDetected), .verifying)
        XCTAssertEqual(try machine.handle(.verificationFinished(success: true, hasNextStep: false)), .completed)
    }

    func testInvalidTransitionThrows() {
        var machine = InstructorStateMachine()
        XCTAssertThrowsError(try machine.handle(.targetGrounded))
    }

    func testCancelAlwaysReturnsToIdle() throws {
        var machine = InstructorStateMachine()
        _ = try machine.handle(.questionReceived)
        XCTAssertEqual(try machine.handle(.cancel), .idle)
    }
}
