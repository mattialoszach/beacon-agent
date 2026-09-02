import SwiftUI

/// Beacon's canonical brand colors. Use semantic system colors for text,
/// materials, destructive actions, and status feedback.
enum BeaconPalette {
    enum Hex {
        static let lavender = 0xE6E6FA
        static let thistle = 0xD8BFD8
        static let plum = 0xDDA0DD
        static let mediumPurple = 0x9370DB
        static let blueViolet = 0x8A2BE2
    }

    static let lavender = Color(hex: Hex.lavender)
    static let thistle = Color(hex: Hex.thistle)
    static let plum = Color(hex: Hex.plum)
    static let mediumPurple = Color(hex: Hex.mediumPurple)
    static let blueViolet = Color(hex: Hex.blueViolet)

    static let accentGradient = LinearGradient(
        colors: [mediumPurple, blueViolet],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let thinkingGradient = Gradient(stops: [
        .init(color: thistle, location: 0),
        .init(color: plum, location: 0.34),
        .init(color: mediumPurple, location: 0.68),
        .init(color: blueViolet, location: 1)
    ])
}

private extension Color {
    init(hex: Int) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
