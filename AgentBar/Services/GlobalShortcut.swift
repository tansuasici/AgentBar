import AppKit
import Carbon.HIToolbox

/// Registers a global keyboard shortcut to toggle the menu bar popup.
/// Default: Control + Option + M (⌃⌥M)
@MainActor
final class GlobalShortcut {
    private var eventMonitor: Any?
    private var onTrigger: (() -> Void)?

    private var keyCode: UInt16 {
        UInt16(UserDefaults.standard.integer(forKey: "shortcutKeyCode").nonZeroOr(kVK_ANSI_M))
    }

    private var modifiers: NSEvent.ModifierFlags {
        let raw = UserDefaults.standard.integer(forKey: "shortcutModifiers")
        if raw > 0 {
            return NSEvent.ModifierFlags(rawValue: UInt(raw))
        }
        return [.control, .option]
    }

    func register(onTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger
        unregister()

        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            let targetMods: NSEvent.ModifierFlags = [.control, .option, .command, .shift]
            if event.keyCode == self.keyCode &&
                event.modifierFlags.intersection(targetMods) == self.modifiers.intersection(targetMods) {
                Task { @MainActor in
                    self.onTrigger?()
                }
            }
        }
    }

    func unregister() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    deinit {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

private extension Int {
    func nonZeroOr(_ fallback: Int) -> Int {
        self != 0 ? self : fallback
    }
}
