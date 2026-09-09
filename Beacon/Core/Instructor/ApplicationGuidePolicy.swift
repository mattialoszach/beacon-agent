import Foundation

struct GuideRecipeStep: Equatable, Sendable {
    let instruction: String
    let targetAliases: [String]
    let expectedOutcome: ExpectedOutcome
    let overlay: OverlayStyle
    var targetRole: String? = nil
    var canSkipIfNextVisible = false
    var alreadySatisfiedBy: ExpectedElement? = nil
    var prerequisite: ExpectedElement? = nil
}

struct ApplicationGuideRecipe: Equatable, Sendable {
    let id: String
    let requestTerms: Set<String>
    var minimumRequestTermMatches = 1
    let steps: [GuideRecipeStep]

    func matches(_ question: String) -> Bool {
        let normalized = Self.tokens(question)
        return !requestTerms.isDisjoint(with: normalized)
            && requestTerms.intersection(normalized).count >= min(minimumRequestTermMatches, requestTerms.count)
    }

    private static func tokens(_ value: String) -> Set<String> {
        Set(value.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }
}

struct ApplicationGuidePolicy: Equatable, Sendable {
    let bundleIdentifier: String
    let recipes: [ApplicationGuideRecipe]
    let recoveryHint: String
    let maximumUnexpectedChangeRetries: Int
    let maximumNoChangeRetries: Int
}

struct GuideRecoveryDecision: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        case retry
        case stop
    }

    let action: Action
    let message: String
}

struct ApplicationGuidePolicyRegistry: Sendable {
    let policies: [ApplicationGuidePolicy]

    init(policies: [ApplicationGuidePolicy] = Self.builtInPolicies) {
        self.policies = policies
    }

    func policy(for bundleIdentifier: String?) -> ApplicationGuidePolicy? {
        guard let bundleIdentifier else { return nil }
        return policies.first { $0.bundleIdentifier == bundleIdentifier }
    }

    func recipe(for request: InstructorRequest) -> ApplicationGuideRecipe? {
        policy(for: request.scene.activeApplication.bundleIdentifier)?.recipes.first {
            $0.matches(request.question)
        }
    }

    func recoveryDecision(
        for bundleIdentifier: String?,
        attempt: Int,
        noChange: Bool,
        expectedDescription: String?
    ) -> GuideRecoveryDecision {
        let policy = policy(for: bundleIdentifier)
        let limit = noChange
            ? policy?.maximumNoChangeRetries ?? 1
            : policy?.maximumUnexpectedChangeRetries ?? 2
        let expectation = expectedDescription.map { " Expected: \($0)" } ?? ""
        if attempt <= limit {
            let hint = policy?.recoveryHint
                ?? "Keep the target application in front and use the highlighted control once."
            return GuideRecoveryDecision(
                action: .retry,
                message: "Beacon did not confirm the step. \(hint)\(expectation)"
            )
        }
        return GuideRecoveryDecision(
            action: .stop,
            message: "Beacon stopped this guide because the expected result could not be confirmed.\(expectation)"
        )
    }

    static let builtInPolicies: [ApplicationGuidePolicy] = [
        ApplicationGuidePolicy(
            bundleIdentifier: "com.apple.TextEdit",
            recipes: [
                exportPDFRecipe(preview: false),
                printRecipe
            ],
            recoveryHint: "In TextEdit, keep the document window active and leave any File menu or save sheet open.",
            maximumUnexpectedChangeRetries: 2,
            maximumNoChangeRetries: 2
        ),
        ApplicationGuidePolicy(
            bundleIdentifier: "com.apple.Preview",
            recipes: [
                exportPDFRecipe(preview: true),
                printRecipe
            ],
            recoveryHint: "In Preview, keep the document window active and leave any File menu or export sheet open.",
            maximumUnexpectedChangeRetries: 2,
            maximumNoChangeRetries: 2
        ),
        ApplicationGuidePolicy(
            bundleIdentifier: "com.apple.finder",
            recipes: [
                ApplicationGuideRecipe(
                    id: "new-folder",
                    requestTerms: ["new", "folder"],
                    minimumRequestTermMatches: 2,
                    steps: [
                        menuStep("Open the File menu.", aliases: ["File"], reveals: ["New Folder"]),
                        GuideRecipeStep(
                            instruction: "Choose New Folder.",
                            targetAliases: ["New Folder"],
                            expectedOutcome: ExpectedOutcome(
                                type: .elementAppears,
                                description: "A new folder should appear."
                            ),
                            overlay: .spotlight
                        )
                    ]
                )
            ],
            recoveryHint: "In Finder, keep the intended folder window active and leave the File menu open.",
            maximumUnexpectedChangeRetries: 2,
            maximumNoChangeRetries: 2
        ),
        ApplicationGuidePolicy(
            bundleIdentifier: "com.apple.Safari",
            recipes: [
                ApplicationGuideRecipe(
                    id: "open-settings",
                    requestTerms: ["settings", "preferences"],
                    steps: [
                        menuStep("Open the Safari menu.", aliases: ["Safari"], reveals: ["Settings", "Preferences"]),
                        GuideRecipeStep(
                            instruction: "Choose Settings.",
                            targetAliases: ["Settings…", "Settings", "Preferences…", "Preferences"],
                            expectedOutcome: ExpectedOutcome(
                                type: .windowAppears,
                                description: "Safari Settings should appear.",
                                element: ExpectedElement(labels: ["General"])
                            ),
                            overlay: .spotlight
                        )
                    ]
                )
            ],
            recoveryHint: "In Safari, keep the browser window active and leave the Safari menu open.",
            maximumUnexpectedChangeRetries: 2,
            maximumNoChangeRetries: 2
        ),
        ApplicationGuidePolicy(
            bundleIdentifier: "com.apple.systempreferences",
            recipes: [
                ApplicationGuideRecipe(
                    id: "dark-appearance",
                    requestTerms: ["dark"],
                    steps: [
                        GuideRecipeStep(
                            instruction: "Open Appearance.",
                            targetAliases: ["Appearance"],
                            expectedOutcome: ExpectedOutcome(
                                type: .elementAppears,
                                description: "The Light, Dark, and Auto appearance choices should appear.",
                                element: ExpectedElement(labels: ["Dark"], role: "AXRadioButton")
                            ),
                            overlay: .spotlight,
                            targetRole: "AXRow",
                            canSkipIfNextVisible: true
                        ),
                        GuideRecipeStep(
                            instruction: "Choose Dark.",
                            targetAliases: ["Dark"],
                            expectedOutcome: ExpectedOutcome(
                                type: .visualChange,
                                description: "Dark appearance should be selected.",
                                element: ExpectedElement(
                                    labels: ["Dark"], role: "AXRadioButton", value: "1"
                                )
                            ),
                            overlay: .spotlight,
                            targetRole: "AXRadioButton",
                            alreadySatisfiedBy: ExpectedElement(
                                labels: ["Dark"], role: "AXRadioButton", value: "1"
                            )
                        )
                    ]
                ),
                ApplicationGuideRecipe(
                    id: "screen-recording-permission",
                    requestTerms: ["screen", "recording"],
                    minimumRequestTermMatches: 2,
                    steps: [
                        GuideRecipeStep(
                            instruction: "Open Privacy & Security.",
                            targetAliases: ["Privacy & Security", "Privacy"],
                            expectedOutcome: ExpectedOutcome(
                                type: .elementAppears,
                                description: "Privacy controls should appear.",
                                element: ExpectedElement(labels: ["Screen & System Audio Recording", "Screen Recording"])
                            ),
                            overlay: .spotlight
                        ),
                        GuideRecipeStep(
                            instruction: "Open Screen & System Audio Recording.",
                            targetAliases: ["Screen & System Audio Recording", "Screen Recording"],
                            expectedOutcome: ExpectedOutcome(
                                type: .elementAppears,
                                description: "The screen-recording application list should appear.",
                                element: ExpectedElement(labels: ["Beacon"], role: "AXCheckBox")
                            ),
                            overlay: .spotlight
                        ),
                        GuideRecipeStep(
                            instruction: "Turn on Beacon in the application list. macOS may ask you to restart Beacon.",
                            targetAliases: ["Beacon"],
                            expectedOutcome: ExpectedOutcome(
                                type: .visualChange,
                                description: "Beacon's screen-recording permission should become enabled.",
                                element: ExpectedElement(labels: ["Beacon"], role: "AXCheckBox", value: "1")
                            ),
                            overlay: .spotlight,
                            // A value change can never be observed when the switch is
                            // already on, so that state completes the step instead.
                            alreadySatisfiedBy: ExpectedElement(
                                labels: ["Beacon"], role: "AXCheckBox", value: "1"
                            )
                        )
                    ]
                )
            ],
            recoveryHint: "In System Settings, keep the Privacy & Security page visible while Beacon rechecks it.",
            maximumUnexpectedChangeRetries: 2,
            maximumNoChangeRetries: 2
        )
    ]

    private static func exportPDFRecipe(preview: Bool) -> ApplicationGuideRecipe {
        let exportAliases = preview ? ["Export", "Export…"] : ["Export as PDF", "Export as PDF…"]
        let pdfFormat = ExpectedElement(labels: ["Format"], role: "AXPopUpButton", value: "PDF")
        // A plain Save sheet also contains exactly one enabled Save button, so that alone
        // cannot prove the export sheet appeared. Preview's export sheet is identified by
        // its Format popup; TextEdit's has no control the save sheet lacks, so its step
        // asks the user to confirm rather than risk recording a wrong success.
        let exportSheetEvidence = preview
            ? ExpectedOutcome(
                type: .windowAppears,
                description: "The export sheet with a Format popup should appear.",
                element: ExpectedElement(labels: ["Format"], role: "AXPopUpButton")
            )
            : ExpectedOutcome(
                type: .windowAppears,
                description: "The Export as PDF sheet should appear. Check that it is the export sheet and not the ordinary Save sheet."
            )
        var steps = [
            menuStep("Open the File menu.", aliases: ["File"], reveals: exportAliases),
            GuideRecipeStep(
                instruction: "Choose the PDF export command.",
                targetAliases: exportAliases,
                expectedOutcome: exportSheetEvidence,
                overlay: .spotlight, targetRole: "AXMenuItem", canSkipIfNextVisible: true
            )
        ]
        if preview {
            steps += [
                GuideRecipeStep(
                    instruction: "Open the Format menu in the export sheet.",
                    targetAliases: ["Format"],
                    expectedOutcome: ExpectedOutcome(type: .elementAppears, description: "The PDF format option should appear.",
                        element: ExpectedElement(labels: ["PDF"], role: "AXMenuItem")),
                    overlay: .spotlight, targetRole: "AXPopUpButton", canSkipIfNextVisible: true,
                    alreadySatisfiedBy: pdfFormat
                ),
                GuideRecipeStep(
                    instruction: "Choose PDF as the export format.",
                    targetAliases: ["PDF"],
                    expectedOutcome: ExpectedOutcome(type: .visualChange, description: "Format should be set to PDF.", element: pdfFormat),
                    overlay: .spotlight, targetRole: "AXMenuItem", alreadySatisfiedBy: pdfFormat
                )
            ]
        }
        steps.append(GuideRecipeStep(
            instruction: "Choose Save to finish exporting the PDF.",
            targetAliases: ["Save"],
            expectedOutcome: ExpectedOutcome(type: .windowDisappears,
                description: "Check that the PDF was saved at your chosen location. Closing or cancelling the sheet does not confirm an export."),
            overlay: .spotlight, targetRole: "AXButton", prerequisite: preview ? pdfFormat : nil
        ))
        return ApplicationGuideRecipe(id: "export-pdf", requestTerms: ["export", "pdf"],
            minimumRequestTermMatches: 2, steps: steps)
    }

    private static let printRecipe = ApplicationGuideRecipe(
        id: "print", requestTerms: ["print"], steps: [
            menuStep("Open the File menu.", aliases: ["File"], reveals: ["Print"]),
            GuideRecipeStep(
                instruction: "Choose Print.", targetAliases: ["Print…", "Print"],
                expectedOutcome: ExpectedOutcome(type: .windowAppears, description: "The print sheet should appear.",
                    element: ExpectedElement(labels: ["Print"], role: "AXButton")),
                overlay: .spotlight, targetRole: "AXMenuItem"
            )
        ]
    )

    private static func menuStep(_ instruction: String, aliases: [String], reveals: [String]) -> GuideRecipeStep {
        GuideRecipeStep(
            instruction: instruction, targetAliases: aliases,
            expectedOutcome: ExpectedOutcome(type: .elementAppears, description: "The requested menu command should appear.",
                element: ExpectedElement(labels: reveals, role: "AXMenuItem")),
            overlay: .spotlight, targetRole: "AXMenuBarItem", canSkipIfNextVisible: true
        )
    }
}

struct ApplicationGuidePlanner: Sendable {
    let registry: ApplicationGuidePolicyRegistry

    init(registry: ApplicationGuidePolicyRegistry = ApplicationGuidePolicyRegistry()) {
        self.registry = registry
    }

    func response(for request: InstructorRequest) -> InstructorResponse? {
        guard let recipe = registry.recipe(for: request) else { return nil }
        let completed = request.guideContext?.completedSteps ?? []
        let completedCount = recipe.steps.lastIndex(where: { step in
            completed.contains { $0.instruction == step.instruction }
        }).map { $0 + 1 } ?? 0
        guard completedCount < recipe.steps.count else {
            return InstructorResponse(
                message: "The guided steps are complete.",
                action: nil,
                expectedOutcome: nil,
                taskComplete: true
            )
        }

        var index = completedCount
        while index < recipe.steps.count {
            let candidate = recipe.steps[index]
            if let selector = candidate.alreadySatisfiedBy,
               matchesUnique(selector, in: request) {
                index += 1
                continue
            }
            // After skipping navigation, evaluate the newly selected step from the top
            // of the loop as well. Its state may already satisfy the user's goal.
            if candidate.canSkipIfNextVisible,
               recipe.steps.indices.contains(index + 1),
               match(step: recipe.steps[index + 1], request: request) != nil {
                index += 1
                continue
            }
            break
        }
        guard index < recipe.steps.count else {
            // Every remaining step is already satisfied, so the task is done.
            return InstructorResponse(
                message: "That is already set up the way you asked.",
                action: nil,
                expectedOutcome: nil,
                taskComplete: true
            )
        }
        let step = recipe.steps[index]
        guard let selected = match(step: step, request: request) else {
            // Before the recipe has committed to anything, an unmatched control usually
            // means a localized or restructured interface, not a stuck task. Defer to the
            // model instead of dead-ending a request it could still answer.
            guard completedCount > 0 else { return nil }
            return InstructorResponse(
                message: "I can’t safely locate the next control. \(step.instruction) Keep the intended window or sheet visible, then start a new request.",
                action: nil, expectedOutcome: nil, taskComplete: false
            )
        }
        return InstructorResponse(
            message: step.instruction,
            action: SuggestedAction(type: .pointToElement, targetElementId: selected.id,
                targetBounds: nil, overlay: step.overlay),
            expectedOutcome: step.expectedOutcome,
            taskComplete: false,
            completesTaskAfterSuccess: index == recipe.steps.index(before: recipe.steps.endIndex)
        )
    }

    private func matchesUnique(_ selector: ExpectedElement, in request: InstructorRequest) -> Bool {
        SceneIdentity.elements(in: request.scene, windowID: request.scene.activeWindow?.id)
            .filter {
                $0.enabled && selector.matches(elementForMatching($0, request: request))
            }
            .count == 1
    }

    private func match(step: GuideRecipeStep, request: InstructorRequest) -> UIElementDescriptor? {
        if let prerequisite = step.prerequisite, !matchesUnique(prerequisite, in: request) { return nil }
        let selector = ExpectedElement(labels: step.targetAliases, role: step.targetRole)
        let elements = SceneIdentity.elements(in: request.scene, windowID: request.scene.activeWindow?.id)
            .filter {
                $0.enabled && $0.bounds?.isValid == true
                    && selector.matches(elementForMatching($0, request: request))
            }
        guard elements.count == 1 else { return nil }
        return elements.first
    }

    /// Local OCR can label an otherwise unlabelled SwiftUI Accessibility row. The
    /// Set-of-Marks builder keeps that label attached to the stable AX element ID; recipes
    /// consume the same local fusion instead of dropping to a generic model step.
    private func elementForMatching(
        _ element: UIElementDescriptor,
        request: InstructorRequest
    ) -> UIElementDescriptor {
        guard !element.hasExplicitLabel,
              let mark = request.setOfMarks.first(where: {
                  $0.elementID == element.id && $0.visualElementID != nil
              }) else { return element }
        return UIElementDescriptor(
            id: element.id,
            role: element.role,
            subrole: element.subrole,
            label: mark.label,
            title: element.title,
            value: element.value,
            enabled: element.enabled,
            focused: element.focused,
            bounds: element.bounds,
            windowID: element.windowID,
            selected: element.selected
        )
    }
}
