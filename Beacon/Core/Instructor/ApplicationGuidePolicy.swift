import Foundation

struct GuideRecipeStep: Equatable, Sendable {
    let instruction: String
    let targetAliases: [String]
    let expectedOutcome: ExpectedOutcome
    let overlay: OverlayStyle
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
                exportPDFRecipe(exportAliases: ["Export as PDF", "Export as PDF…", "PDF"]),
                printRecipe
            ],
            recoveryHint: "In TextEdit, keep the document window active and leave any File menu or save sheet open.",
            maximumUnexpectedChangeRetries: 2,
            maximumNoChangeRetries: 2
        ),
        ApplicationGuidePolicy(
            bundleIdentifier: "com.apple.Preview",
            recipes: [
                exportPDFRecipe(exportAliases: ["Export", "Export…", "PDF"]),
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
                        menuStep("Open the File menu.", aliases: ["File"]),
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
                        menuStep("Open the Safari menu.", aliases: ["Safari"]),
                        GuideRecipeStep(
                            instruction: "Choose Settings.",
                            targetAliases: ["Settings…", "Settings", "Preferences…", "Preferences"],
                            expectedOutcome: ExpectedOutcome(
                                type: .windowAppears,
                                description: "Safari Settings should appear."
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
                    id: "screen-recording-permission",
                    requestTerms: ["screen", "recording"],
                    minimumRequestTermMatches: 2,
                    steps: [
                        GuideRecipeStep(
                            instruction: "Open Privacy & Security.",
                            targetAliases: ["Privacy & Security", "Privacy"],
                            expectedOutcome: ExpectedOutcome(
                                type: .elementAppears,
                                description: "Privacy controls should appear."
                            ),
                            overlay: .spotlight
                        ),
                        GuideRecipeStep(
                            instruction: "Open Screen & System Audio Recording.",
                            targetAliases: ["Screen & System Audio Recording", "Screen Recording"],
                            expectedOutcome: ExpectedOutcome(
                                type: .elementAppears,
                                description: "The screen-recording application list should appear."
                            ),
                            overlay: .spotlight
                        ),
                        GuideRecipeStep(
                            instruction: "Turn on Beacon in the application list. macOS may ask you to restart Beacon.",
                            targetAliases: ["Beacon"],
                            expectedOutcome: ExpectedOutcome(
                                type: .visualChange,
                                description: "Beacon's screen-recording permission should become enabled."
                            ),
                            overlay: .spotlight
                        )
                    ]
                )
            ],
            recoveryHint: "In System Settings, keep the Privacy & Security page visible while Beacon rechecks it.",
            maximumUnexpectedChangeRetries: 2,
            maximumNoChangeRetries: 2
        )
    ]

    private static func exportPDFRecipe(exportAliases: [String]) -> ApplicationGuideRecipe {
        ApplicationGuideRecipe(
            id: "export-pdf",
            requestTerms: ["export", "pdf"],
            minimumRequestTermMatches: 2,
            steps: [
                menuStep("Open the File menu.", aliases: ["File"]),
                GuideRecipeStep(
                    instruction: "Choose the PDF export command.",
                    targetAliases: exportAliases,
                    expectedOutcome: ExpectedOutcome(
                        type: .windowAppears,
                        description: "An export or save sheet should appear."
                    ),
                    overlay: .spotlight
                ),
                GuideRecipeStep(
                    instruction: "Choose Save to finish exporting the PDF.",
                    targetAliases: ["Save", "Export"],
                    expectedOutcome: ExpectedOutcome(
                        type: .windowDisappears,
                        description: "The export sheet should close."
                    ),
                    overlay: .spotlight
                )
            ]
        )
    }

    private static let printRecipe = ApplicationGuideRecipe(
        id: "print",
        requestTerms: ["print"],
        steps: [
            menuStep("Open the File menu.", aliases: ["File"]),
            GuideRecipeStep(
                instruction: "Choose Print.",
                targetAliases: ["Print…", "Print"],
                expectedOutcome: ExpectedOutcome(
                    type: .windowAppears,
                    description: "The print sheet should appear."
                ),
                overlay: .spotlight
            )
        ]
    )

    private static func menuStep(_ instruction: String, aliases: [String]) -> GuideRecipeStep {
        GuideRecipeStep(
            instruction: instruction,
            targetAliases: aliases,
            expectedOutcome: ExpectedOutcome(
                type: .elementAppears,
                description: "The menu commands should appear."
            ),
            overlay: .spotlight
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
        let completedCount = request.guideContext?.completedSteps.count ?? 0
        guard completedCount < recipe.steps.count else {
            return InstructorResponse(
                message: "The guided steps are complete.",
                action: nil,
                expectedOutcome: nil,
                taskComplete: true
            )
        }

        let current = match(step: recipe.steps[completedCount], request: request)
        let next = recipe.steps.indices.contains(completedCount + 1)
            ? match(step: recipe.steps[completedCount + 1], request: request)
            : nil
        let selected: StepMatch?
        if let current, current.opensNavigation, let next {
            selected = next
        } else {
            selected = current ?? next
        }
        guard let selected else { return nil }

        return InstructorResponse(
            message: selected.step.instruction,
            action: SuggestedAction(
                type: .pointToElement,
                targetElementId: selected.elementID,
                targetBounds: nil,
                targetMark: selected.markID,
                overlay: selected.step.overlay
            ),
            expectedOutcome: selected.step.expectedOutcome,
            taskComplete: false
        )
    }

    private func match(step: GuideRecipeStep, request: InstructorRequest) -> StepMatch? {
        let completedIDs = Set(request.guideContext?.completedSteps.compactMap(\.targetElementID) ?? [])
        let elements = request.scene.elements.filter { !completedIDs.contains($0.id) && $0.enabled && $0.bounds != nil }
        if let element = elements.max(by: {
            aliasScore($0.bestLabel, aliases: step.targetAliases) < aliasScore($1.bestLabel, aliases: step.targetAliases)
        }), aliasScore(element.bestLabel, aliases: step.targetAliases) > 0 {
            return StepMatch(
                step: step,
                elementID: element.id,
                markID: nil,
                opensNavigation: element.role == "AXMenuBarItem"
                    || step.expectedOutcome.description == "The menu commands should appear."
            )
        }

        if let mark = request.setOfMarks.max(by: {
            aliasScore($0.label, aliases: step.targetAliases) < aliasScore($1.label, aliases: step.targetAliases)
        }), aliasScore(mark.label, aliases: step.targetAliases) > 0 {
            return StepMatch(
                step: step,
                elementID: mark.elementID,
                markID: mark.elementID == nil ? mark.id : nil,
                opensNavigation: false
            )
        }
        return nil
    }

    private func aliasScore(_ candidate: String, aliases: [String]) -> Double {
        let normalizedCandidate = normalized(candidate)
        return aliases.map { alias -> Double in
            let normalizedAlias = normalized(alias)
            if normalizedCandidate == normalizedAlias { return 1 }
            if normalizedCandidate.contains(normalizedAlias) || normalizedAlias.contains(normalizedCandidate) { return 0.75 }
            return SemanticElementMatcher.relevanceScore(query: alias, candidate: candidate) * 0.6
        }.max() ?? 0
    }

    private func normalized(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: "…", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct StepMatch {
        let step: GuideRecipeStep
        let elementID: String?
        let markID: Int?
        let opensNavigation: Bool
    }
}
