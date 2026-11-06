import Carbon.HIToolbox

/// System-wide hotkey via Carbon. Unlike event taps, this needs no Accessibility permission.
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private static var actions: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1

    init(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        let id = HotKey.nextID
        HotKey.nextID += 1
        HotKey.actions[id] = action

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let action = HotKey.actions[hotKeyID.id]
            DispatchQueue.main.async { action?() }
            return noErr
        }, 1, &spec, nil, &handlerRef)

        let hotKeyID = EventHotKeyID(signature: OSType(0x5348_5458), id: id) // 'SHTX'
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
