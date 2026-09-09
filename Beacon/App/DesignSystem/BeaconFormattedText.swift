import Foundation
import SwiftUI

enum BeaconMarkdown {
    static func attributedString(_ source: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: source, options: options))
            ?? AttributedString(source)
    }

    static func plainText(_ source: String) -> String {
        String(attributedString(source).characters)
    }
}

struct BeaconFormattedText: View {
    let source: String

    init(_ source: String) {
        self.source = source
    }

    var body: some View {
        Text(BeaconMarkdown.attributedString(source))
    }
}
