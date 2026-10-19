import AppKit
import ApplicationServices

/// Reads the text currently selected in the frontmost app.
@MainActor
enum SelectionCapture {
    static let clipboard = ClipboardWatcher()

    static func capture() async -> String? {
        if let text = accessibilitySelectedText(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        if let text = await copyViaClipboard(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        return clipboard.takeRecentCopy(from: NSWorkspace.shared.frontmostApplication?.processIdentifier)
    }

    /// Fast path: ask the focused UI element for its selection. Native Cocoa apps support this;
    /// many browsers and Electron apps don't, so we fall back to ⌘C.
    private static func accessibilitySelectedText() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSelectedTextAttribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    /// Slow path: send ⌘C to the frontmost app, read the clipboard, then put the old clipboard back.
    private static func copyViaClipboard() async -> String? {
        let pb = NSPasteboard.general
        let saved: [[NSPasteboard.PasteboardType: Data]] = (pb.pasteboardItems ?? []).map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { dict[type] = data }
            }
            return dict
        }
        let before = pb.changeCount

        postCommandC()
        for _ in 0..<16 {
            try? await Task.sleep(nanoseconds: 25_000_000)
            if pb.changeCount != before { break }
        }
        guard pb.changeCount != before else { return nil }
        // Give the source app a moment to finish writing all representations.
        try? await Task.sleep(nanoseconds: 20_000_000)
        let text = pb.string(forType: .string)

        pb.clearContents()
        let restored = saved.map { dict -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in dict { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { pb.writeObjects(restored) }
        clipboard.ignoreCurrentContents()
        return text
    }

    private static func postCommandC() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyC: CGKeyCode = 0x08
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyC, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyC, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

/// Remembers when the clipboard last changed and which app was in front at the time.
///
/// Some apps keep their own selection instead of a native one and copy it to the clipboard
/// on mouse release — notably Claude Code's fullscreen TUI, which captures the mouse in the
/// terminal. By the time Shift is tapped twice there is no selection left to read, but the
/// text was put on the clipboard moments ago by that same app, so we use that instead.
@MainActor
final class ClipboardWatcher {
    struct Change: Equatable {
        let count: Int
        let date: Date
        let appPID: pid_t?
    }

    /// How old a copy may be and still count as "what you just selected".
    nonisolated static let maxAge: TimeInterval = 30

    private(set) var lastChange: Change?
    private var seenCount = NSPasteboard.general.changeCount
    private var consumedCount: Int?
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func poll() {
        let count = NSPasteboard.general.changeCount
        guard count != seenCount else { return }
        seenCount = count
        lastChange = Change(count: count, date: Date(), appPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
    }

    /// Call after writing to the clipboard ourselves so that write is never mistaken for a copy.
    func ignoreCurrentContents() {
        seenCount = NSPasteboard.general.changeCount
        lastChange = nil
    }

    /// Returns the clipboard text if `appPID` copied it recently and it hasn't been captured yet.
    func takeRecentCopy(from appPID: pid_t?) -> String? {
        poll()
        let pb = NSPasteboard.general
        guard ClipboardWatcher.isUsable(lastChange, currentCount: pb.changeCount, frontPID: appPID,
                                        consumedCount: consumedCount, now: Date()),
              let text = pb.string(forType: .string)
        else { return nil }
        consumedCount = pb.changeCount
        return text
    }

    nonisolated static func isUsable(_ change: Change?, currentCount: Int, frontPID: pid_t?,
                                     consumedCount: Int?, now: Date) -> Bool {
        guard let change, let frontPID,
              change.count == currentCount,   // clipboard still holds that copy
              change.count != consumedCount,  // and it wasn't saved already
              change.appPID == frontPID       // and it came from the app you're in
        else { return false }
        return now.timeIntervalSince(change.date) <= maxAge
    }
}
