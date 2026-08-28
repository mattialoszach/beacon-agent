import Foundation

struct ApplicationDescriptor: Codable, Equatable, Sendable {
    let name: String
    let bundleIdentifier: String?
    let processIdentifier: Int32
}

struct WindowDescriptor: Codable, Equatable, Sendable {
    let title: String?
    let bounds: NormalizedRect?
}

struct DisplayDescriptor: Codable, Equatable, Identifiable, Sendable {
    let id: UInt32
    let bounds: NormalizedRect
    let scaleFactor: Double
}

struct ScreenSnapshot: Codable, Equatable, Sendable {
    let capturedAt: Date
    let displayID: UInt32
    let pixelWidth: Int
    let pixelHeight: Int
    let displayBounds: NormalizedRect
    let pngData: Data
    let redactionCount: Int
}

struct UIElementDescriptor: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: String
    let role: String?
    let subrole: String?
    let label: String?
    let title: String?
    let value: String?
    let enabled: Bool
    let focused: Bool
    let bounds: NormalizedRect?

    var bestLabel: String {
        [label, title, value]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? "Unlabelled control"
    }
}

struct ScreenScene: Codable, Equatable, Sendable {
    let timestamp: Date
    let activeApplication: ApplicationDescriptor
    let activeWindow: WindowDescriptor?
    let screenshot: ScreenSnapshot?
    let elements: [UIElementDescriptor]
    let displays: [DisplayDescriptor]
}
