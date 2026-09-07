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
    private let maximumCaptureDimension = 1_920

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
                || Self.alwaysExcludedBundleIdentifiers.contains(application.bundleIdentifier)
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApplications,
            exceptingWindows: []
        )
        let configuration = SCStreamConfiguration()
        // SCDisplay reports points; SCStreamConfiguration expects pixels. Passing points
        // through would capture every Retina display at 1x and blur small text for OCR.
        let pixelSize = Self.pixelSize(of: display)
        let dimensions = ScreenCaptureDimensions.fitting(
            pixelWidth: pixelSize.width,
            pixelHeight: pixelSize.height,
            maximumDimension: maximumCaptureDimension
        )
        configuration.width = dimensions.width
        configuration.height = dimensions.height
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

    /// Notification banners are drawn by Notification Center, not by the application that
    /// posted them, so an excluded application's alert would otherwise reach the capture.
    static let alwaysExcludedBundleIdentifiers: Set<String> = [
        "com.apple.notificationcenterui"
    ]

    /// Backing pixel size of a display. `CGDisplayPixelsWide` reports the logical mode
    /// size, so only the display mode exposes the true Retina pixel dimensions.
    static func pixelSize(of display: SCDisplay) -> (width: Int, height: Int) {
        guard let mode = CGDisplayCopyDisplayMode(display.displayID) else {
            return (display.width, display.height)
        }
        let width = mode.pixelWidth > 0 ? mode.pixelWidth : display.width
        let height = mode.pixelHeight > 0 ? mode.pixelHeight : display.height
        return (width, height)
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

struct ScreenCaptureDimensions: Equatable, Sendable {
    let width: Int
    let height: Int

    static func fitting(
        pixelWidth: Int,
        pixelHeight: Int,
        maximumDimension: Int
    ) -> ScreenCaptureDimensions {
        guard pixelWidth > 0, pixelHeight > 0, maximumDimension > 0 else {
            return ScreenCaptureDimensions(width: max(1, pixelWidth), height: max(1, pixelHeight))
        }
        let longestEdge = max(pixelWidth, pixelHeight)
        guard longestEdge > maximumDimension else {
            return ScreenCaptureDimensions(width: pixelWidth, height: pixelHeight)
        }
        let scale = Double(maximumDimension) / Double(longestEdge)
        return ScreenCaptureDimensions(
            width: max(1, Int((Double(pixelWidth) * scale).rounded())),
            height: max(1, Int((Double(pixelHeight) * scale).rounded()))
        )
    }
}
