import XCTest
@testable import Beacon

final class RequestModeClassifierTests: XCTestCase {
    private let classifier = RequestModeClassifier(semanticScorer: FixedSemanticScorer(ask: 0.5, guide: 0.5))

    func testExplanatoryRequestsAreQuestions() {
        XCTAssertEqual(classifier.classify("What does this warning mean?"), .ask)
        XCTAssertEqual(classifier.classify("Why is this disabled?"), .ask)
        XCTAssertEqual(classifier.classify("How does this tool work?"), .ask)
    }

    func testActionableRequestsStartGuidance() {
        XCTAssertEqual(classifier.classify("Where is Export?"), .guide)
        XCTAssertEqual(classifier.classify("How do I export as PDF?"), .guide)
        XCTAssertEqual(classifier.classify("Export this as a PDF"), .guide)
    }

    func testExplanationWinsEvenWhenItNamesAnAction() {
        XCTAssertEqual(classifier.classify("What does Export do?"), .ask)
    }

    func testVisibleSceneTargetResolvesAnOtherwiseAmbiguousRequest() {
        let pdf = UIElementDescriptor(
            id: "e_pdf", role: "AXButton", subrole: nil, label: "PDF", title: nil,
            value: nil, enabled: true, focused: false,
            bounds: .init(x: 0.2, y: 0.2, width: 0.1, height: 0.05)
        )
        let scene = ScreenScene(
            timestamp: Date(),
            activeApplication: .init(name: "Fixture", bundleIdentifier: "test", processIdentifier: 1),
            activeWindow: nil,
            screenshot: nil,
            elements: [pdf],
            displays: []
        )

        XCTAssertEqual(classifier.classify("PDF", scene: scene), .guide)
    }

    func testSemanticScorerHandlesRequestsWithoutKnownPhrases() {
        let semanticClassifier = RequestModeClassifier(
            semanticScorer: FixedSemanticScorer(ask: 0.05, guide: 0.95)
        )

        let result = semanticClassifier.classification(for: "Assist with the task in front of me")

        XCTAssertEqual(result.mode, .guide)
        XCTAssertGreaterThan(result.confidence, 0.6)
        XCTAssertTrue(result.evidence.contains("semantic action match"))
    }
}

private struct FixedSemanticScorer: RequestModeSemanticScoring {
    let ask: Double
    let guide: Double

    func scores(for request: String) -> RequestModeSemanticScores? {
        RequestModeSemanticScores(ask: ask, guide: guide)
    }
}

final class LocationPhrasingClassifierTests: XCTestCase {
    private let classifier = RequestModeClassifier(semanticScorer: NeutralScorer())

    /// "Where is X" and "Where's X" are the same request and must route the same way.
    func testContractedAndPluralLocationQuestionsAskForGuidance() {
        for question in [
            "Where is the sidebar toggle?",
            "Where's the sidebar toggle?",
            "Where are my downloads?",
            "Where do i change the theme?"
        ] {
            XCTAssertEqual(classifier.classify(question), .guide, "\(question) should guide")
        }
    }

    func testExplanationQuestionsStillAnswer() {
        for question in ["What is this warning?", "Why is this disabled?", "Explain this dialog"] {
            XCTAssertEqual(classifier.classify(question), .ask, "\(question) should answer")
        }
    }
}

/// Keeps the classifier deterministic and independent of the on-device embedding model.
private struct NeutralScorer: RequestModeSemanticScoring {
    func scores(for request: String) -> RequestModeSemanticScores? {
        RequestModeSemanticScores(ask: 0.5, guide: 0.5)
    }
}
