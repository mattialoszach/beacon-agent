import XCTest
@testable import Beacon

final class SensitiveTextDetectorTests: XCTestCase {
    private let detector = SensitiveTextDetector()

    func testClassifiesCommonSensitiveValues() {
        XCTAssertEqual(detector.kind(of: "person@example.com"), .emailAddress)
        XCTAssertEqual(detector.kind(of: "+41 79 123 45 67"), .phoneNumber)
        XCTAssertEqual(detector.kind(of: "4242 4242 4242 4242"), .creditCard)
        XCTAssertEqual(detector.kind(of: "sk-abcdefghijklmnopqrstuvwxyz1234"), .apiKey)
    }

    func testDoesNotRedactOrdinaryUILabels() {
        XCTAssertNil(detector.kind(of: "Export as PDF"))
        XCTAssertNil(detector.kind(of: "Page 12 of 85"))
    }

    func testSensitiveVisualElementsAreRemovedAndMappedToRegions() {
        let elements = [
            visual(id: "safe", text: "Save"),
            visual(id: "secret", text: "person@example.com")
        ]
        XCTAssertEqual(detector.removingSensitiveElements(from: elements).map(\.id), ["safe"])
        XCTAssertEqual(detector.redactionRegions(in: elements).count, 1)
    }

    private func visual(id: String, text: String) -> VisualElementDescriptor {
        .init(id: id, text: text, bounds: .init(x: 0.1, y: 0.1, width: 0.2, height: 0.05), confidence: 0.9)
    }
}

final class SensitiveTextLineScopedDetectionTests: XCTestCase {
    private let detector = SensitiveTextDetector()

    /// Vision returns whole lines, so a card or phone number usually shares its line with
    /// unrelated digits. Counting every digit in the line used to miss these entirely.
    func testCardNumberIsFoundBesideUnrelatedDigits() {
        XCTAssertEqual(detector.kind(of: "Card 4242 4242 4242 4242  Exp 12/26"), .creditCard)
        XCTAssertEqual(detector.kind(of: "Order 88213 · 4242-4242-4242-4242 · $19.99"), .creditCard)
    }

    func testPhoneNumberIsFoundBesideUnrelatedDigits() {
        XCTAssertEqual(detector.kind(of: "Tel +1 (415) 555-2671 · Fax +1 (415) 555-2672"), .phoneNumber)
        XCTAssertEqual(detector.kind(of: "Row 12: +41 79 123 45 67"), .phoneNumber)
    }

    func testDigitRunsThatAreNotCardsStayVisible() {
        XCTAssertNil(detector.kind(of: "Build 20260907 items 1234"), "An ungrouped identifier is not a phone number")
        XCTAssertNil(detector.kind(of: "1111 2222 3333 4445"), "A failed Luhn check is not a card")
    }

    func testRecognisesCommonAPIKeyFormats() {
        let keys = [
            "sk_live_51Hxxxxxxxxxxxxxxxxxxxxxxxx",
            "AIzaSyA1234567890abcdefghijklmnopqrstuv",
            "xoxb-1234567890-abcdefghij",
            "glpat-abcdefghijklmnopqrstu",
            "hf_abcdefghijklmnopqrstuvwxyz",
            "AKIAIOSFODNN7EXAMPLE",
            "ghp_abcdefghijklmnopqrstuvwxyz0123",
            "-----BEGIN RSA PRIVATE KEY-----",
            "-----END RSA PRIVATE KEY-----"
        ]
        for key in keys {
            XCTAssertEqual(detector.kind(of: key), .apiKey, "\(key) must be treated as a key")
            XCTAssertEqual(detector.kind(of: "Token: \(key) (copied)"), .apiKey)
        }
    }

    func testClassifyReturnsRegionsAndSafeElementsInOnePass() {
        let elements = [
            visual(id: "safe", text: "Save"),
            visual(id: "card", text: "Card 4242 4242 4242 4242 Exp 12/26"),
            visual(id: "key", text: "sk_live_51Hxxxxxxxxxxxxxxxxxxxxxxxx")
        ]

        let classified = detector.classify(elements)

        XCTAssertEqual(classified.safeElements.map(\.id), ["safe"])
        XCTAssertEqual(classified.regions.count, 2)
        XCTAssertTrue(classified.regions.allSatisfy { $0.category == .detectedSensitiveText })
        // The single pass must agree with the individual helpers it replaces.
        XCTAssertEqual(classified.regions, detector.redactionRegions(in: elements))
        XCTAssertEqual(
            classified.safeElements.map(\.id),
            detector.removingSensitiveElements(from: elements).map(\.id)
        )
    }

    func testClassifyRedactsEveryOCRLineInAPEMBlockAndDerivedLabels() {
        let body = "MIIEowIBAAKCAQEAu7J7wWZQsqULf4N5R9w0gP8vL2k="
        let elements = [
            visual(id: "before", text: "Connection settings"),
            visual(id: "begin", text: "-----BEGIN RSA PRIVATE KEY-----"),
            visual(id: "body", text: body),
            visual(id: "end", text: "-----END RSA PRIVATE KEY-----"),
            visual(id: "derived", text: "\(body) rectangle control", kind: .rectangle),
            visual(id: "after", text: "Save")
        ]

        XCTAssertNil(detector.kind(of: body), "A base64 line needs its PEM block context")
        let classified = detector.classify(elements)

        XCTAssertEqual(classified.safeElements.map(\.id), ["before", "after"])
        XCTAssertEqual(classified.regions.count, 4)
        XCTAssertEqual(detector.removingSensitiveElements(from: elements), classified.safeElements)
        XCTAssertEqual(detector.redactionRegions(in: elements), classified.regions)
    }

    private func visual(
        id: String,
        text: String,
        kind: VisualElementKind = .text
    ) -> VisualElementDescriptor {
        .init(
            id: id,
            text: text,
            bounds: .init(x: 0.1, y: 0.1, width: 0.2, height: 0.05),
            confidence: 0.9,
            kind: kind
        )
    }
}
