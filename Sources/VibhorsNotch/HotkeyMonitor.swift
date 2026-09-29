import AppKit

/// Detects hold-to-talk on modifier keys pressed on their own:
/// Right ⌘ for the assistant, Fn/🌐 for dictation.
/// Pressing any other key while holding cancels, so ⌘-shortcuts and Fn-arrows still work.
/// Needs Accessibility permission to see keys pressed in other apps.
final class HotkeyMonitor {
    enum Key { case rightCommand, function }

    var onPress: ((Key) -> Void)?
    /// `cancelled` is true for accidental taps and when another key was pressed.
    var onRelease: ((Key, _ cancelled: Bool) -> Void)?

    private var held: Key?
    private var pressedAt = Date()
    private var monitors: [Any] = []

    private static let rightCommandKeyCode: UInt16 = 54
    private static let functionKeyCode: UInt16 = 63
    private static let minimumHold: TimeInterval = 0.15

    static func ensureAccessibility(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func start() {
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] in self?.handle($0) }) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handle(event)
            return event
        }) {
            monitors.append(m)
        }
    }

    private func handle(_ event: NSEvent) {
        if event.type == .keyDown {
            if let key = held { finish(key, cancelled: true) }
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
        switch event.keyCode {
        case Self.rightCommandKeyCode:
            if held == .rightCommand {
                finish(.rightCommand, cancelled: false)
            } else if held == nil, flags == .command {
                begin(.rightCommand)
            }
        case Self.functionKeyCode:
            if held == .function {
                finish(.function, cancelled: false)
            } else if held == nil, flags == .function {
                begin(.function)
            }
        default:
            // Another modifier joined the hold (e.g. ⌘⇧): it's a shortcut, not push-to-talk.
            if let key = held { finish(key, cancelled: true) }
        }
    }

    private func begin(_ key: Key) {
        held = key
        pressedAt = Date()
        onPress?(key)
    }

    private func finish(_ key: Key, cancelled: Bool) {
        held = nil
        let tooShort = Date().timeIntervalSince(pressedAt) < Self.minimumHold
        onRelease?(key, cancelled || tooShort)
    }
}
