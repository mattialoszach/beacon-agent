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

enum VisualElementKind: String, Codable, CaseIterable, Hashable, Sendable {
    case text
    case rectangle
    case circle
    case icon
    case canvasShape

    var displayName: String {
        switch self {
        case .text: "Text"
        case .rectangle: "Rectangle"
        case .circle: "Circle"
        case .icon: "Icon"
        case .canvasShape: "Canvas shape"
        }
    }
}

struct VisualElementDescriptor: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: String
    let text: String
    let bounds: NormalizedRect
    let confidence: Double
    let kind: VisualElementKind

    init(
        id: String,
        text: String,
        bounds: NormalizedRect,
        confidence: Double,
        kind: VisualElementKind = .text
    ) {
        self.id = id
        self.text = text
        self.bounds = bounds
        self.confidence = confidence
        self.kind = kind
    }

    var bestLabel: String {
        let label = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? kind.displayName : label
    }
}

struct ScreenScene: Codable, Equatable, Sendable {
    let timestamp: Date
    let activeApplication: ApplicationDescriptor
    let activeWindow: WindowDescriptor?
    let screenshot: ScreenSnapshot?
    let elements: [UIElementDescriptor]
    var visualElements: [VisualElementDescriptor] = []
    let displays: [DisplayDescriptor]
}

extension ScreenScene {
    func replacingScreenshot(with snapshot: ScreenSnapshot?) -> ScreenScene {
        ScreenScene(
            timestamp: timestamp,
            activeApplication: activeApplication,
            activeWindow: activeWindow,
            screenshot: snapshot,
            elements: elements,
            visualElements: visualElements,
            displays: displays
        )
    }

    func replacingVisualElements(with visualElements: [VisualElementDescriptor]) -> ScreenScene {
        ScreenScene(
            timestamp: timestamp,
            activeApplication: activeApplication,
            activeWindow: activeWindow,
            screenshot: screenshot,
            elements: elements,
            visualElements: visualElements,
            displays: displays
        )
    }
}
