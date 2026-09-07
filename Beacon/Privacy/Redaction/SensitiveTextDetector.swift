import Foundation

enum SensitiveTextKind: String, CaseIterable, Sendable {
    case emailAddress
    case phoneNumber
    case creditCard
    case apiKey
}

struct SensitiveTextDetector: Sendable {
    func kind(of text: String) -> SensitiveTextKind? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if Patterns.email.matches(trimmed) { return .emailAddress }
        if Patterns.apiKey.matches(trimmed) { return .apiKey }
        // OCR returns whole lines, so a card or phone number usually shares its line with
        // unrelated digits. Each candidate run is checked on its own instead of counting
        // every digit in the line.
        if Patterns.cardCandidate.matchedSubstrings(in: trimmed).contains(where: isCardNumber) {
            return .creditCard
        }
        if Patterns.phoneCandidate.matchedSubstrings(in: trimmed).contains(where: isPhoneNumber) {
            return .phoneNumber
        }
        return nil
    }

    func redactionRegions(in elements: [VisualElementDescriptor]) -> [RedactionRegion] {
        classify(elements).regions
    }

    func removingSensitiveElements(from elements: [VisualElementDescriptor]) -> [VisualElementDescriptor] {
        classify(elements).safeElements
    }

    /// Classifies each element once and returns both the masks and the safe elements, so
    /// a capture does not run the same classification three times over the same strings.
    func classify(
        _ elements: [VisualElementDescriptor]
    ) -> (regions: [RedactionRegion], safeElements: [VisualElementDescriptor]) {
        let pemBlockElements = sensitivePEMBlockElements(in: elements)
        let pemElementIDs = Set(pemBlockElements.map(\.id))
        // Shape descriptors can copy nearby OCR text into their labels. Propagate every
        // PEM line to those derived descriptors so the bounded text context cannot retain
        // a key body after its original OCR element was removed.
        let pemFragments = pemBlockElements
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 8 }
        var regions: [RedactionRegion] = []
        var safeElements: [VisualElementDescriptor] = []
        for element in elements {
            let containsPEMFragment = pemFragments.contains { fragment in
                element.text.contains(fragment)
            }
            if kind(of: element.text) == nil,
               !pemElementIDs.contains(element.id),
               !containsPEMFragment {
                safeElements.append(element)
            } else {
                regions.append(
                    RedactionRegion(bounds: element.bounds, category: .detectedSensitiveText)
                )
            }
        }
        return (regions, safeElements)
    }

    /// Vision returns one descriptor per OCR line. Once a PEM header is seen, every text
    /// line through the matching footer belongs to the same secret even though a base64
    /// body line is not independently recognisable as a credential.
    private func sensitivePEMBlockElements(
        in elements: [VisualElementDescriptor]
    ) -> [VisualElementDescriptor] {
        var isInsidePEMBlock = false
        var sensitive: [VisualElementDescriptor] = []
        for element in elements where element.kind == .text {
            if Patterns.pemBegin.matches(element.text) {
                isInsidePEMBlock = true
            }
            guard isInsidePEMBlock else { continue }
            sensitive.append(element)
            if Patterns.pemEnd.matches(element.text) {
                isInsidePEMBlock = false
            }
        }
        return sensitive
    }

    private func isCardNumber(_ candidate: String) -> Bool {
        let digits = candidate.filter(\.isNumber)
        return (13...19).contains(digits.count) && luhnIsValid(digits)
    }

    private func isPhoneNumber(_ candidate: String) -> Bool {
        let digitCount = candidate.filter(\.isNumber).count
        guard (7...15).contains(digitCount) else { return false }
        // A bare run of digits with no grouping is far more often an identifier, a build
        // number or an amount. Real numbers are written with separators or are long.
        let isGrouped = candidate.contains { "+-() ".contains($0) }
        return isGrouped || digitCount >= 10
    }

    private func luhnIsValid(_ digits: String) -> Bool {
        let numbers = digits.compactMap(\.wholeNumberValue)
        guard numbers.count == digits.count else { return false }
        let sum = numbers.reversed().enumerated().reduce(0) { partial, pair in
            var value = pair.element
            if pair.offset.isMultiple(of: 2) == false {
                value *= 2
                if value > 9 { value -= 9 }
            }
            return partial + value
        }
        return sum > 0 && sum.isMultiple(of: 10)
    }
}

/// Compiled once. `String.range(of:options:.regularExpression)` rebuilds its expression on
/// every call, which a text-dense capture makes thousands of times.
private struct CompiledPattern: Sendable {
    private let expression: NSRegularExpression?

    init(_ pattern: String, options: NSRegularExpression.Options = [.caseInsensitive]) {
        expression = try? NSRegularExpression(pattern: pattern, options: options)
    }

    func matches(_ value: String) -> Bool {
        guard let expression else { return false }
        return expression.firstMatch(
            in: value,
            range: NSRange(value.startIndex..., in: value)
        ) != nil
    }

    func matchedSubstrings(in value: String) -> [String] {
        guard let expression else { return [] }
        return expression
            .matches(in: value, range: NSRange(value.startIndex..., in: value))
            .compactMap { Range($0.range, in: value).map { String(value[$0]) } }
    }
}

private enum Patterns {
    static let email = CompiledPattern(#"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#)

    static let apiKey = CompiledPattern(
        [
            #"\bsk-[A-Za-z0-9_-]{16,}\b"#,
            #"\bAKIA[A-Z0-9]{16}\b"#,
            #"\bgh[pousr]_[A-Za-z0-9]{20,}\b"#,
            #"\b(?:sk|pk|rk)_(?:live|test)_[A-Za-z0-9]{16,}\b"#,
            #"\bAIza[0-9A-Za-z_-]{35}\b"#,
            #"\bxox[abprs]-[A-Za-z0-9-]{10,}\b"#,
            #"\bglpat-[A-Za-z0-9_-]{20,}\b"#,
            #"\bhf_[A-Za-z0-9]{20,}\b"#,
            #"\bnpm_[A-Za-z0-9]{30,}\b"#,
            #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#,
            #"-----END [A-Z ]*PRIVATE KEY-----"#
        ].joined(separator: "|")
    )

    static let pemBegin = CompiledPattern(#"-----BEGIN [A-Z ]*PRIVATE KEY-----"#)
    static let pemEnd = CompiledPattern(#"-----END [A-Z ]*PRIVATE KEY-----"#)

    /// A run of 13 to 19 digits with optional single spaces or hyphens between them.
    static let cardCandidate = CompiledPattern(
        #"(?<![0-9])(?:[0-9][ -]?){12,18}[0-9](?![0-9])"#,
        options: []
    )

    static let phoneCandidate = CompiledPattern(
        #"(?<![\w])\+?[0-9][0-9 ().-]{5,}[0-9](?![\w])"#,
        options: []
    )
}
