import AppKit
import CoreGraphics
import Foundation

enum PermissionKind: String, CaseIterable, Identifiable, Hashable, Sendable {
    case accessibility = "Accessibility"
    case screenRecording = "Screen Recording"

    var id: String { rawValue }

    /// Privacy & Security pane for this permission. The anchors below are stable across
    /// macOS 13 through 26.
    var settingsURL: URL? {
        switch self {
        case .accessibility:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        case .screenRecording:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        }
    }
}

struct PermissionCenter {
    func isGranted(_ permission: PermissionKind) -> Bool {
        switch permission {
        case .accessibility: AccessibilityService().isTrusted()
        case .screenRecording: CGPreflightScreenCaptureAccess()
        }
    }

    /// macOS shows each system prompt only once per app identity. After a denial the
    /// request call returns silently, so the user is taken to the pane instead.
    @discardableResult
    func request(_ permission: PermissionKind) -> Bool {
        switch permission {
        case .accessibility: _ = AccessibilityService().isTrusted(prompt: true)
        case .screenRecording: _ = CGRequestScreenCaptureAccess()
        }
        guard !isGranted(permission) else { return true }
        openSettings(for: permission)
        return false
    }

    func openSettings(for permission: PermissionKind) {
        guard let url = permission.settingsURL else { return }
        NSWorkspace.shared.open(url)
    }
}
