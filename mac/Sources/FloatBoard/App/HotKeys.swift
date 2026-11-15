import FloatBoardCore
import Carbon

/// System-wide keyboard shortcuts via Carbon (no Accessibility permission needed).
enum HotKeys {
    nonisolated(unsafe) private static var handlers: [UInt32: () -> Void] = [:]
    nonisolated(unsafe) private static var installed = false
    nonisolated(unsafe) private static var refs: [EventHotKeyRef] = []

    static func register(id: UInt32, keyCode: Int, modifiers: Int, _ handler: @escaping () -> Void) {
        if !installed {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hk = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
                HotKeys.handlers[hk.id]?()
                return noErr
            }, 1, &spec, nil, nil)
            installed = true
        }
        handlers[id] = handler
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers),
                            EventHotKeyID(signature: OSType(0x46_42_44_31), id: id), // "FBD1"
                            GetApplicationEventTarget(), 0, &ref)
        if let ref { refs.append(ref) }
    }
}
