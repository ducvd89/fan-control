import Carbon
import Foundation

/// Global shortcuts ⌃⌥⌘1 … ⌃⌥⌘9 switch to profile 1…9, and ⌃⌥⌘0 cycles to the next one.
/// Carbon hot keys need no Accessibility permission.
final class HotKeys {
    nonisolated(unsafe) private static var handler: ((Int) -> Void)?
    private var refs: [EventHotKeyRef?] = []

    // Virtual key codes for the number row 1…9, then 0.
    private static let keyCodes: [Int] = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                                          kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9, kVK_ANSI_0]

    /// `onPress` receives 0…8 for profiles 1…9 and -1 for "next profile".
    init(onPress: @escaping (Int) -> Void) {
        Self.handler = onPress
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let index = Int(id.id)
            DispatchQueue.main.async { HotKeys.handler?(index == 9 ? -1 : index) }
            return noErr
        }, 1, &spec, nil, nil)

        let mods = UInt32(controlKey | optionKey | cmdKey)
        for (i, code) in Self.keyCodes.enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x46414E43) /* 'FANC' */, id: UInt32(i))
            RegisterEventHotKey(UInt32(code), mods, id, GetApplicationEventTarget(), 0, &ref)
            refs.append(ref)
        }
    }

    deinit { refs.forEach { if let r = $0 { UnregisterEventHotKey(r) } } }
}
