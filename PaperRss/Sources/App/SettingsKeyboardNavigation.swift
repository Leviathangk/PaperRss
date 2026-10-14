#if os(macOS)
import AppKit
import SwiftUI

/// Scope settings navigation to its window and active lifetime. Native editors,
/// sheets and popovers retain their keyboard events.
struct SettingsKeyboardNavigation: NSViewRepresentable {
    var isActive: Bool
    var onActivate: () -> Void
    var onKey: (NSEvent, NSWindow) -> Bool

    final class NavigationView: NSView {
        var isActive = false
        var onActivate: (() -> Void)?
        var onKey: ((NSEvent, NSWindow) -> Bool)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { stop() }
            if window != nil, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    let handled = MainActor.assumeIsolated { () -> Bool in
                        guard let self, let window = self.window,
                              Self.shouldHandle(event, in: window, isActive: self.isActive) else { return false }
                        return self.onKey?(event, window) == true
                    }
                    return handled ? nil : event
                }
            }
        }

        func setActive(_ active: Bool) {
            guard isActive != active else { return }
            isActive = active
            if active {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isActive else { return }
                    self.onActivate?()
                }
            }
        }

        static func shouldHandle(_ event: NSEvent, in window: NSWindow, isActive: Bool) -> Bool {
            let disallowed: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
            return isActive && event.window === window
                && window.attachedSheet == nil && NSApp.modalWindow == nil
                && event.modifierFlags.intersection(disallowed).isEmpty
                && !(window.firstResponder is NSTextView)
                && !(window.firstResponder is NSTextField)
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }

    func makeNSView(context: Context) -> NavigationView { NavigationView() }

    func updateNSView(_ view: NavigationView, context: Context) {
        view.onActivate = onActivate
        view.onKey = onKey
        view.setActive(isActive)
    }

    static func dismantleNSView(_ view: NavigationView, coordinator: ()) { view.stop() }

    static func moveFocus(in window: NSWindow, backwards: Bool, from event: NSEvent) {
        guard let tab = NSEvent.keyEvent(
            with: .keyDown, location: event.locationInWindow,
            modifierFlags: backwards ? [.shift] : [], timestamp: event.timestamp,
            windowNumber: window.windowNumber, context: nil, characters: "\t",
            charactersIgnoringModifiers: "\t", isARepeat: event.isARepeat, keyCode: 48
        ) else { return }
        window.firstResponder?.keyDown(with: tab)
    }
}
#endif
