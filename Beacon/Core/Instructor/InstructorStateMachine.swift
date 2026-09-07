import Foundation

enum InstructorState: String, Codable, Equatable, Sendable {
    case idle
    case understanding
    case capturingScene
    case grounding
    case presenting
    case awaitingContextRestore
    case waitingForChange
    case awaitingConfirmation
    case verifying
    case completed
    case failed
}

enum InstructorEvent: Equatable, Sendable {
    case questionReceived
    case sceneCaptured
    case responseGenerated(needsTarget: Bool)
    case targetGrounded
    case contextLost
    case contextRestored
    case contextChanged
    case instructionPresented(expectsChange: Bool)
    case meaningfulChangeDetected
    case confirmationRequested
    case resultConfirmed
    case verificationFinished(success: Bool, hasNextStep: Bool)
    case cancel
    case fail
}

struct InstructorStateMachine: Equatable, Sendable {
    private(set) var state: InstructorState = .idle

    @discardableResult
    mutating func handle(_ event: InstructorEvent) throws -> InstructorState {
        if event == .cancel {
            state = .idle
            return state
        }
        if event == .fail {
            state = .failed
            return state
        }

        switch (state, event) {
        case (.idle, .questionReceived): state = .capturingScene
        case (.capturingScene, .sceneCaptured): state = .understanding
        case let (.understanding, .responseGenerated(needsTarget)): state = needsTarget ? .grounding : .presenting
        case (.grounding, .targetGrounded): state = .presenting
        case (.presenting, .contextLost): state = .awaitingContextRestore
        case (.awaitingContextRestore, .contextRestored): state = .capturingScene
        case (.presenting, .contextChanged), (.waitingForChange, .contextChanged),
             (.awaitingContextRestore, .contextChanged):
            state = .capturingScene
        case let (.presenting, .instructionPresented(expectsChange)):
            state = expectsChange ? .waitingForChange : .completed
        case (.waitingForChange, .meaningfulChangeDetected): state = .verifying
        // The user can complete the expected step while Beacon waits for a lost context
        // to return; that is a verified outcome, not a failed restoration.
        case (.awaitingContextRestore, .meaningfulChangeDetected): state = .verifying
        case (.presenting, .confirmationRequested), (.waitingForChange, .confirmationRequested):
            state = .awaitingConfirmation
        case (.awaitingConfirmation, .resultConfirmed): state = .verifying
        case let (.verifying, .verificationFinished(success, hasNextStep)):
            state = success ? (hasNextStep ? .capturingScene : .completed) : .presenting
        default: throw StateTransitionError.invalid(state: state, event: event)
        }
        return state
    }
}

enum StateTransitionError: LocalizedError, Equatable {
    case invalid(state: InstructorState, event: InstructorEvent)

    var errorDescription: String? {
        switch self {
        case let .invalid(state, event): "Invalid instructor transition from \(state.rawValue) using \(event)."
        }
    }
}
