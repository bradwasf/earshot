import Carbon.HIToolbox
import SwiftUI

/// A system-wide keyboard shortcut, registered with Carbon's `RegisterEventHotKey`. Unlike a
/// global key monitor it needs no Accessibility permission, and it never sees other keystrokes.
@MainActor
final class GlobalHotKey: ObservableObject {
    enum State: Equatable {
        case off
        case registered
        /// Another app holds the same shortcut (or macOS refused it).
        case unavailable
    }

    /// ⌃⌥⌘R: Record's ⌘R with modifiers that system and common app shortcuts leave free.
    static let display = "⌃⌥⌘R"
    private static let keyCode = UInt32(kVK_ANSI_R)
    private static let modifiers = UInt32(controlKey | optionKey | cmdKey)
    private static let signature: OSType = 0x4561_7273  // "Ears"

    @Published private(set) var state: State = .off
    /// True between a press that starts a recording and the recording starting.
    var startPending = false

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (() -> Void)?

    /// The one instance whose shortcut is registered (Carbon's callback is a C function).
    private static weak var current: GlobalHotKey?

    func setEnabled(_ enabled: Bool, action: @escaping () -> Void) {
        self.action = action
        if enabled { register() } else { unregister() }
    }

    private func register() {
        guard hotKey == nil else { return }
        if handler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(
                GetApplicationEventTarget(),
                { _, event, _ in
                    var id = EventHotKeyID()
                    let status = GetEventParameter(
                        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                        MemoryLayout<EventHotKeyID>.size, nil, &id)
                    guard status == noErr, id.signature == GlobalHotKey.signature else {
                        return OSStatus(eventNotHandledErr)
                    }
                    DispatchQueue.main.async { MainActor.assumeIsolated { GlobalHotKey.current?.action?() } }
                    return noErr
                }, 1, &type, nil, &handler)
            guard status == noErr else {
                Log.write("global shortcut: handler not installed (\(status))")
                state = .unavailable
                return
            }
        }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            Self.keyCode, Self.modifiers, EventHotKeyID(signature: Self.signature, id: 1), GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive), &ref)
        if status == noErr, let ref {
            hotKey = ref
            Self.current = self
            state = .registered
        } else {
            Log.write("global shortcut \(Self.display) not registered (\(status))")
            state = .unavailable
        }
    }

    private func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        state = .off
    }
}
