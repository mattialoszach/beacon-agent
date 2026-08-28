import Carbon
import Foundation

final class GlobalShortcutMonitor {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var action: (() -> Void)?

    deinit { unregister() }

    @discardableResult
    func registerOptionSpace(action: @escaping () -> Void) -> Bool {
        unregister()
        self.action = action

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var receivedID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &receivedID
                )
                guard status == noErr, receivedID.signature == GlobalShortcutMonitor.signature else { return status }
                let monitor = Unmanaged<GlobalShortcutMonitor>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { monitor.action?() }
                return noErr
            },
            1,
            &eventType,
            pointer,
            &handlerRef
        )
        guard handlerStatus == noErr else {
            unregister()
            return false
        }

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
        let hotKeyStatus = RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard hotKeyStatus == noErr else {
            unregister()
            return false
        }
        return true
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
        action = nil
    }

    private static let signature: OSType = 0x42454143 // BEAC
}
