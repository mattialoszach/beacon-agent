import AVFoundation
import CoreGraphics
import Foundation

enum PermissionKind: String, CaseIterable, Identifiable {
    case accessibility = "Accessibility"
    case screenRecording = "Screen Recording"
    case microphone = "Microphone (future)"

    var id: String { rawValue }
}

struct PermissionCenter {
    func isGranted(_ permission: PermissionKind) -> Bool {
        switch permission {
        case .accessibility: AccessibilityService().isTrusted()
        case .screenRecording: CGPreflightScreenCaptureAccess()
        case .microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        }
    }

    func request(_ permission: PermissionKind) {
        switch permission {
        case .accessibility: _ = AccessibilityService().isTrusted(prompt: true)
        case .screenRecording: _ = CGRequestScreenCaptureAccess()
        case .microphone: AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
    }
}
