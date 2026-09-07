import Foundation

enum SceneIdentity {
    static func sameApplication(_ lhs: ScreenScene, _ rhs: ScreenScene) -> Bool {
        lhs.activeApplication.processIdentifier == rhs.activeApplication.processIdentifier
            && lhs.activeApplication.bundleIdentifier == rhs.activeApplication.bundleIdentifier
    }

    static func sameWindow(_ lhs: WindowDescriptor?, _ rhs: WindowDescriptor?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (lhs?, rhs?):
            guard let id = lhs.id, !id.isEmpty else { return false }
            return id == rhs.id
        default: return false
        }
    }

    static func sameDisplays(_ lhs: ScreenScene, _ rhs: ScreenScene) -> Bool {
        lhs.displays.sorted { $0.id < $1.id } == rhs.displays.sorted { $0.id < $1.id }
    }

    /// Every window reachable from `focusedWindowID` by following parent links: its
    /// sheets, and anything presented over those sheets, such as an alert above a compose
    /// sheet. Only checking the immediate parent would drop the alert's controls.
    static func windowIDs(
        relatedTo focusedWindowID: String?,
        in windows: [WindowDescriptor]
    ) -> Set<String> {
        guard let focusedWindowID else { return [] }
        var related: Set<String> = [focusedWindowID]
        var didInsert = true
        while didInsert {
            didInsert = false
            for window in windows {
                guard let id = window.id, !related.contains(id),
                      let parent = window.parentWindowID, related.contains(parent) else { continue }
                related.insert(id)
                didInsert = true
            }
        }
        return related
    }

    static func visibleWindows(in scene: ScreenScene) -> [WindowDescriptor] {
        guard let active = scene.activeWindow else { return scene.windows }
        return scene.windows.contains(where: { $0.id == active.id }) ? scene.windows : scene.windows + [active]
    }

    static func elements(in scene: ScreenScene, windowID: String?) -> [UIElementDescriptor] {
        var windowIDs = Set([windowID].compactMap { $0 })
        for _ in scene.windows {
            for window in scene.windows where window.parentWindowID.map(windowIDs.contains) == true {
                if let id = window.id { windowIDs.insert(id) }
            }
        }
        return scene.elements.filter {
            $0.windowID.map(windowIDs.contains) == true
                || (windowID == nil && $0.windowID == nil)
                || ($0.windowID == nil && ["AXMenuBarItem", "AXMenuItem"].contains($0.role ?? ""))
        }
    }
}
