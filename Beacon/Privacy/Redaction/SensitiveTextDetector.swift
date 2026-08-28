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
        if matches(trimmed, pattern: #"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#) { return .emailAddress }
        if matches(trimmed, pattern: #"\b(?:sk-[A-Za-z0-9_-]{16,}|AKIA[A-Z0-9]{16}|gh[pousr]_[A-Za-z0-9]{20,})\b"#) { return .apiKey }

        let digits = trimmed.filter(\.isNumber)
        if (13...19).contains(digits.count), luhnIsValid(digits) { return .creditCard }
        if (7...15).contains(digits.count),
           matches(trimmed, pattern: #"(?<!\w)(?:\+?\d[\d\s().-]{5,}\d)(?!\w)"#) {
            return .phoneNumber
        }
        return nil
    }

    func redactionRegions(in elements: [VisualElementDescriptor]) -> [RedactionRegion] {
        elements.compactMap { element in
            guard kind(of: element.text) != nil else { return nil }
            return RedactionRegion(bounds: element.bounds, category: .detectedSensitiveText)
        }
    }

    func removingSensitiveElements(from elements: [VisualElementDescriptor]) -> [VisualElementDescriptor] {
        elements.filter { kind(of: $0.text) == nil }
    }

    private func matches(_ value: String, pattern: String) -> Bool {
        value.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
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
