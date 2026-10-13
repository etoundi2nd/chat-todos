import AppKit
import ApplicationServices

/// Reads the text currently selected in the frontmost app.
@MainActor
enum SelectionCapture {
    static func capture() async -> String? {
        if let text = accessibilitySelectedText(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        return await copyViaClipboard()
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
