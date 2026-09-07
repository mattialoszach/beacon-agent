import AppKit

/// Decides whether a local Escape key event belongs to Beacon's guidance or to the window
/// that is currently key.
///
/// Escape must cancel guidance promptly, but a sheet, alert or confirmation dialog owns
/// the key while it is up. Consuming Escape there would cancel the user's guide instead of
/// closing the dialog in front of them.
enum EscapeRouting {
    static let keyCode: UInt16 = 53

    static func handlesEscape(from window: NSWindow?) -> Bool {
        guard let window else { return true }
        return !window.isSheet && window.attachedSheet == nil
    }
}
