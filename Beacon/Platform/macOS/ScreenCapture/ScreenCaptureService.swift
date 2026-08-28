import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

enum ScreenCaptureError: LocalizedError {
    case noDisplay
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .noDisplay: "Beacon could not find a display to capture."
        case .encodingFailed: "Beacon could not encode the privacy preview."
        }
    }
}

struct ScreenCaptureService {
    func captureDisplay(
        containing point: CGPoint? = nil,
        excludingBundleIdentifiers: Set<String> = []
    ) async throws -> ScreenSnapshot {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = chooseDisplay(from: content.displays, point: point) else {
            throw ScreenCaptureError.noDisplay
        }

        let ownBundleID = Bundle.main.bundleIdentifier
        let excludedApplications = content.applications.filter { application in
            excludingBundleIdentifiers.contains(application.bundleIdentifier)
                || application.bundleIdentifier == ownBundleID
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApplications,
            exceptingWindows: []
        )
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.showsCursor = false
        configuration.captureResolution = .best
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )

        let mapper = DisplayGeometryProvider().currentMapper()
        guard let displayBounds = mapper.normalizeAXRect(CGDisplayBounds(display.displayID)) else {
            throw ScreenCaptureError.noDisplay
        }
        return ScreenSnapshot(
            capturedAt: Date(),
            displayID: display.displayID,
            pixelWidth: image.width,
            pixelHeight: image.height,
            displayBounds: displayBounds,
            pngData: try pngData(from: image),
            redactionCount: excludedApplications.filter {
                excludingBundleIdentifiers.contains($0.bundleIdentifier)
            }.count
        )
    }

    private func chooseDisplay(from displays: [SCDisplay], point: CGPoint?) -> SCDisplay? {
        guard let point else { return displays.first { CGDisplayIsMain($0.displayID) != 0 } ?? displays.first }
        return displays.first { CGDisplayBounds($0.displayID).contains(point) }
            ?? displays.first { CGDisplayIsMain($0.displayID) != 0 }
            ?? displays.first
    }

    private func pngData(from image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { throw ScreenCaptureError.encodingFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ScreenCaptureError.encodingFailed }
        return data as Data
    }
}
