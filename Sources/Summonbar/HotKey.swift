import AppKit
import Carbon

/// System-wide hotkey via Carbon's RegisterEventHotKey (no Accessibility permission needed).
final class HotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextId: UInt32 = 1
    private static var installed = false

    private var ref: EventHotKeyRef?
    private let id: UInt32

    /// `spec` looks like "cmd+shift+space" or "option+k".
    init?(_ spec: String, handler: @escaping () -> Void) {
        guard let (keyCode, modifiers) = Self.parse(spec) else { return nil }
        Self.installHandler()
        id = Self.nextId
        Self.nextId += 1
        let hotKeyID = EventHotKeyID(signature: OSType(0x534D_4E42), id: id)  // 'SMNB'
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else { return nil }
        Self.handlers[id] = handler
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        Self.handlers[id] = nil
    }

    private static func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            DispatchQueue.main.async { HotKey.handlers[hotKeyID.id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    static func parse(_ spec: String) -> (UInt32, UInt32)? {
        var modifiers: UInt32 = 0
        var key: UInt32?
        for part in spec.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "cmd", "command", "⌘": modifiers |= UInt32(cmdKey)
            case "shift", "⇧": modifiers |= UInt32(shiftKey)
            case "opt", "option", "alt", "⌥": modifiers |= UInt32(optionKey)
            case "ctrl", "control", "⌃": modifiers |= UInt32(controlKey)
            default: key = keyCodes[part]
            }
        }
        guard let key, modifiers != 0 else { return nil }
        return (key, modifiers)
    }

    static func describe(_ spec: String) -> String {
        let parts = spec.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        let symbols: [String: String] = ["ctrl": "⌃", "control": "⌃", "opt": "⌥", "option": "⌥", "alt": "⌥",
                                         "shift": "⇧", "cmd": "⌘", "command": "⌘", "space": "Space"]
        // Show modifiers in the standard macOS order (⌃⌥⇧⌘) whatever order the spec uses.
        let order = ["⌃", "⌥", "⇧", "⌘"]
        let mapped = parts.map { symbols[$0] ?? $0.uppercased() }
        return order.filter(mapped.contains).joined() + mapped.filter { !order.contains($0) }.joined()
    }

    /// Builds a spec like "cmd+shift+space" from a key press, or nil if the key
    /// isn't supported or no modifier is held.
    static func spec(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> String? {
        guard let key = keyCodes.first(where: { $0.value == UInt32(keyCode) })?.key else { return nil }
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("opt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        guard !parts.isEmpty else { return nil }
        return (parts + [key]).joined(separator: "+")
    }

    private static let keyCodes: [String: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40,
        "n": 45, "m": 46, "space": 49, "return": 36, "tab": 48, "`": 50, ";": 41, "'": 39, ",": 43, ".": 47, "/": 44,
    ]
}
