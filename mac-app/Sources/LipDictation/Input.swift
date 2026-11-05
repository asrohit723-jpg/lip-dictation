import AppKit
import ApplicationServices

/// Watches the hold-to-talk key anywhere in macOS. Needs Accessibility.
///
/// Pressing any other key while holding it means you were using a shortcut
/// (say ⌥-click or ⌥←), so that cancels quietly; Esc cancels with feedback.
final class HoldKey {
    var choice: HoldKeyChoice
    var onDown: () -> Void = {}
    var onUp: () -> Void = {}
    var onCancel: (_ quietly: Bool) -> Void = { _ in }

    private(set) var isDown = false
    private var monitors: [Any] = []

    init(choice: HoldKeyChoice) {
        self.choice = choice
    }

    func start() {
        stop()
        let flags: (NSEvent) -> Void = { [weak self] e in self?.flagsChanged(e) }
        let keys: (NSEvent) -> Void = { [weak self] e in self?.keyDown(e) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: keys) { monitors.append(m) }
        // Our own windows (setup, Settings) get local events instead of global ones.
        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { flags($0); return $0 }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { keys($0); return $0 }) { monitors.append(m) }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        isDown = false
    }

    private func flagsChanged(_ e: NSEvent) {
        guard e.keyCode == choice.keyCode else {
            if isDown, e.modifierFlags.intersection([.command, .control, .shift, .option]).subtracting(choice.flag) != [] {
                isDown = false
                onCancel(true)        // another modifier joined in: it's a shortcut
            }
            return
        }
        let pressed = e.modifierFlags.contains(choice.flag)
        if pressed && !isDown {
            isDown = true
            onDown()
        } else if !pressed && isDown {
            isDown = false
            onUp()
        }
    }

    private func keyDown(_ e: NSEvent) {
        guard isDown else { return }
        isDown = false
        onCancel(e.keyCode != 53)
    }
}

/// Puts text where the cursor is: through the clipboard and ⌘V, then the
/// clipboard gets its previous text back.
enum Paster {
    static var trusted: Bool { AXIsProcessTrusted() }

    /// Shows macOS's "allow Accessibility" prompt.
    static func askForTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    static func paste(_ text: String) {
        let pb = NSPasteboard.general
        let previous = pb.string(forType: .string)
        copy(text)
        let ours = pb.changeCount
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        guard let previous else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            if pb.changeCount == ours { copy(previous) }   // unless something else was copied since
        }
    }

    /// The app that will receive the text, for the history.
    static var frontApp: String { NSWorkspace.shared.frontmostApplication?.localizedName ?? "" }
}

/// What you're writing into, read through Accessibility when you start dictating:
/// the text just before the cursor, so the lip reader can pick words that fit it.
enum FocusContext {
    static func textBeforeCursor(limit: Int = 600) -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let ref = focused, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        let element = ref as! AXUIElement
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        if (subrole as? String) == (kAXSecureTextFieldSubrole as String) { return nil }   // never read passwords
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
              let text = value as? String, !text.isEmpty else { return nil }
        let ns = text as NSString
        var cursor = ns.length
        var range: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success,
           let r = range, CFGetTypeID(r) == AXValueGetTypeID() {
            var cf = CFRange()
            if AXValueGetValue(r as! AXValue, .cfRange, &cf) { cursor = min(max(cf.location, 0), ns.length) }
        }
        let start = max(0, cursor - limit)
        let before = ns.substring(with: NSRange(location: start, length: cursor - start))
        return before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : before
    }
}
