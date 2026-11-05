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

/// Notices when you fix what Lip Dictation just typed.
///
/// Right after pasting, it notes the text field's contents. For the next 45 seconds it looks
/// again every couple of seconds; once the text where the dictation went has changed and you've
/// stopped typing for a few seconds, it hands over what was typed and what it became. Only the
/// dictated stretch is compared: the text before it must be unchanged, and the text after it
/// is matched from the end.
final class CorrectionWatcher {
    private var element: AXUIElement?
    private var before = ""                 // field text before the dictation
    private var after = ""                  // field text after it
    private var inserted = ""
    private var lastSeen = ""
    private var stableSince = Date()
    private var started = Date()
    private var timer: Timer?
    var onCorrection: (_ inserted: String, _ edited: String) -> Void = { _, _ in }

    /// Call right after pasting `text`. Reads the field a moment later, once the paste has landed.
    func watch(inserted text: String) {
        finish()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            guard let el = Self.focusedElement(), let value = Self.value(of: el),
                  let range = value.range(of: text.trimmingCharacters(in: .whitespaces), options: .backwards) else { return }
            element = el
            inserted = String(value[range])
            before = String(value[..<range.lowerBound])
            after = String(value[range.upperBound...])
            lastSeen = value
            started = Date()
            stableSince = Date()
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.check() }
        }
    }

    /// Stop watching, keeping any correction already made (called when a new dictation starts).
    func finish() {
        if timer != nil { check(final: true) }
        timer?.invalidate()
        timer = nil
        element = nil
    }

    private func check(final: Bool = false) {
        guard let el = element, let value = Self.value(of: el) else { return stop() }
        if value != lastSeen {
            lastSeen = value
            stableSince = Date()
        }
        let settled = Date().timeIntervalSince(stableSince) >= 4
        let expired = Date().timeIntervalSince(started) > 45
        guard final || settled || expired else { return }
        if let edited = editedStretch(in: value), edited != inserted {
            onCorrection(inserted, edited)
            return stop()
        }
        if expired || final { stop() }
    }

    private func editedStretch(in value: String) -> String? {
        Self.editedStretch(before: before, after: after, now: value)
    }

    /// What the dictated stretch reads now, if the text before it is intact.
    static func editedStretch(before: String, after: String, now value: String) -> String? {
        guard value.hasPrefix(before) else { return nil }
        let rest = value.dropFirst(before.count)
        // the text that followed the dictation, if it's still there, marks where the stretch ends
        let tail = after.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty, let r = rest.range(of: tail, options: .backwards) {
            return String(rest[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        element = nil
    }

    static func focusedElement() -> AXUIElement? {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString,
                                            &focused) == .success,
              let ref = focused, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }

    static func value(of el: AXUIElement) -> String? {
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &subrole)
        if (subrole as? String) == (kAXSecureTextFieldSubrole as String) { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
