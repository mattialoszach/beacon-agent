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

    func testConfirmationCanOnlyAdvanceAfterExplicitConfirmation() throws {
        var machine = InstructorStateMachine()
        _ = try machine.handle(.questionReceived)
        _ = try machine.handle(.sceneCaptured)
        _ = try machine.handle(.responseGenerated(needsTarget: false))
        XCTAssertEqual(try machine.handle(.confirmationRequested), .awaitingConfirmation)
        XCTAssertThrowsError(try machine.handle(.meaningfulChangeDetected))
        XCTAssertThrowsError(try machine.handle(.verificationFinished(success: true, hasNextStep: false)))
        XCTAssertEqual(try machine.handle(.resultConfirmed), .verifying)
        XCTAssertEqual(try machine.handle(.verificationFinished(success: true, hasNextStep: true)), .capturingScene)
    }

    func testInvalidTransitionThrows() {
        var machine = InstructorStateMachine()
        XCTAssertThrowsError(try machine.handle(.targetGrounded))
    }

    func testContextChangeReplansWithoutClaimingVerification() throws {
        for phase in [InstructorState.presenting, .waitingForChange, .awaitingContextRestore] {
            var machine = InstructorStateMachine()
            try machine.handle(.questionReceived)
            try machine.handle(.sceneCaptured)
            try machine.handle(.responseGenerated(needsTarget: true))
            try machine.handle(.targetGrounded)
            if phase == .waitingForChange { try machine.handle(.instructionPresented(expectsChange: true)) }
            if phase == .awaitingContextRestore { try machine.handle(.contextLost) }
            XCTAssertEqual(try machine.handle(.contextChanged), .capturingScene)
            XCTAssertThrowsError(try machine.handle(.verificationFinished(success: true, hasNextStep: true)))
            XCTAssertEqual(try machine.handle(.sceneCaptured), .understanding)
        }
    }

    func testCancelAlwaysReturnsToIdle() throws {
        var machine = InstructorStateMachine()
        _ = try machine.handle(.questionReceived)
        XCTAssertEqual(try machine.handle(.cancel), .idle)
    }

    func testStalePresentationWaitsForContextAndThenRecaptures() throws {
        var machine = InstructorStateMachine()
        _ = try machine.handle(.questionReceived)
        _ = try machine.handle(.sceneCaptured)
        _ = try machine.handle(.responseGenerated(needsTarget: true))
        _ = try machine.handle(.targetGrounded)

        XCTAssertEqual(try machine.handle(.contextLost), .awaitingContextRestore)
        XCTAssertEqual(try machine.handle(.contextRestored), .capturingScene)
    }
}

/// AGENTS.md requires every transition to be explicit and tested. This table pins the
/// complete arrow set: a new or removed arrow must be reflected here.
final class InstructorStateMachineTableTests: XCTestCase {
    private static let allStates: [InstructorState] = [
        .idle, .capturingScene, .understanding, .grounding, .presenting,
        .awaitingContextRestore, .waitingForChange, .awaitingConfirmation,
        .verifying, .completed, .failed
    ]

    private static let events: [InstructorEvent] = [
        .questionReceived, .sceneCaptured, .responseGenerated(needsTarget: true),
        .responseGenerated(needsTarget: false), .targetGrounded, .contextLost,
        .contextRestored, .contextChanged, .instructionPresented(expectsChange: true),
        .instructionPresented(expectsChange: false), .meaningfulChangeDetected,
        .confirmationRequested, .resultConfirmed,
        .verificationFinished(success: true, hasNextStep: true),
        .verificationFinished(success: true, hasNextStep: false),
        .verificationFinished(success: false, hasNextStep: false)
    ]

    /// Every legal (state, event) pair and its destination. Everything else must throw.
    private static let legalTransitions: [InstructorState: [(InstructorEvent, InstructorState)]] = [
        .idle: [(.questionReceived, .capturingScene)],
        .capturingScene: [(.sceneCaptured, .understanding)],
        .understanding: [
            (.responseGenerated(needsTarget: true), .grounding),
            (.responseGenerated(needsTarget: false), .presenting)
        ],
        .grounding: [(.targetGrounded, .presenting)],
        .presenting: [
            (.contextLost, .awaitingContextRestore),
            (.contextChanged, .capturingScene),
            (.instructionPresented(expectsChange: true), .waitingForChange),
            (.instructionPresented(expectsChange: false), .completed),
            (.confirmationRequested, .awaitingConfirmation)
        ],
        .awaitingContextRestore: [
            (.contextRestored, .capturingScene),
            (.contextChanged, .capturingScene),
            (.meaningfulChangeDetected, .verifying)
        ],
        .waitingForChange: [
            (.contextChanged, .capturingScene),
            (.meaningfulChangeDetected, .verifying),
            (.confirmationRequested, .awaitingConfirmation)
        ],
        .awaitingConfirmation: [(.resultConfirmed, .verifying)],
        .verifying: [
            (.verificationFinished(success: true, hasNextStep: true), .capturingScene),
            (.verificationFinished(success: true, hasNextStep: false), .completed),
            (.verificationFinished(success: false, hasNextStep: false), .presenting)
        ],
        .completed: [],
        .failed: []
    ]

    private func machine(in state: InstructorState) throws -> InstructorStateMachine {
        var machine = InstructorStateMachine()
        switch state {
        case .idle: break
        case .capturingScene:
            try machine.handle(.questionReceived)
        case .understanding:
            try machine.handle(.questionReceived); try machine.handle(.sceneCaptured)
        case .grounding:
            try machine.handle(.questionReceived); try machine.handle(.sceneCaptured)
            try machine.handle(.responseGenerated(needsTarget: true))
        case .presenting:
            try machine.handle(.questionReceived); try machine.handle(.sceneCaptured)
            try machine.handle(.responseGenerated(needsTarget: false))
        case .awaitingContextRestore:
            try machine.handle(.questionReceived); try machine.handle(.sceneCaptured)
            try machine.handle(.responseGenerated(needsTarget: false))
            try machine.handle(.contextLost)
        case .waitingForChange:
            try machine.handle(.questionReceived); try machine.handle(.sceneCaptured)
            try machine.handle(.responseGenerated(needsTarget: false))
            try machine.handle(.instructionPresented(expectsChange: true))
        case .awaitingConfirmation:
            try machine.handle(.questionReceived); try machine.handle(.sceneCaptured)
            try machine.handle(.responseGenerated(needsTarget: false))
            try machine.handle(.confirmationRequested)
        case .verifying:
            try machine.handle(.questionReceived); try machine.handle(.sceneCaptured)
            try machine.handle(.responseGenerated(needsTarget: false))
            try machine.handle(.instructionPresented(expectsChange: true))
            try machine.handle(.meaningfulChangeDetected)
        case .completed:
            try machine.handle(.questionReceived); try machine.handle(.sceneCaptured)
            try machine.handle(.responseGenerated(needsTarget: false))
            try machine.handle(.instructionPresented(expectsChange: false))
        case .failed:
            try machine.handle(.fail)
        }
        XCTAssertEqual(machine.state, state, "Fixture did not reach \(state)")
        return machine
    }

    func testEveryStateEventPairMatchesTheDeclaredTable() throws {
        for state in Self.allStates {
            let expected = Self.legalTransitions[state] ?? []
            for event in Self.events {
                var subject = try machine(in: state)
                let destination = expected.first { $0.0 == event }?.1
                if let destination {
                    XCTAssertEqual(
                        try subject.handle(event), destination,
                        "\(state) + \(event) should reach \(destination)"
                    )
                } else {
                    XCTAssertThrowsError(
                        try subject.handle(event),
                        "\(state) + \(event) must be rejected"
                    ) { error in
                        XCTAssertEqual(
                            error as? StateTransitionError,
                            .invalid(state: state, event: event)
                        )
                    }
                }
            }
        }
    }

    func testCancelAndFailAreAcceptedFromEveryState() throws {
        for state in Self.allStates {
            var cancelling = try machine(in: state)
            XCTAssertEqual(try cancelling.handle(.cancel), .idle)

            var failing = try machine(in: state)
            XCTAssertEqual(try failing.handle(.fail), .failed)
        }
    }

    func testFailedVerificationRepresentsTheStepAndCanEnterRecovery() throws {
        var machine = try machine(in: .verifying)

        XCTAssertEqual(
            try machine.handle(.verificationFinished(success: false, hasNextStep: false)),
            .presenting
        )
        XCTAssertEqual(try machine.handle(.contextLost), .awaitingContextRestore)
    }

    func testStepCompletedWhileAwaitingContextRestoreVerifies() throws {
        var machine = try machine(in: .awaitingContextRestore)

        XCTAssertEqual(try machine.handle(.meaningfulChangeDetected), .verifying)
        XCTAssertEqual(
            try machine.handle(.verificationFinished(success: true, hasNextStep: true)),
            .capturingScene
        )
    }
}
