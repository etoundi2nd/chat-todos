import AppKit
import ApplicationServices
import Carbon
import ServiceManagement
import SwiftUI

@main
enum ChatTodosMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    let settings = AppSettings()
    private lazy var settingsWindow = SettingsWindowController(settings: settings)
    private let panel = FloatingPanel()
    private let toast = ToastController()
    private let shiftMonitor = ShiftTapMonitor()
    private var statusItem: NSStatusItem!
    private var hotKeys: [HotKey] = []
    private var lastExternalApp: NSRunningApplication?
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpMainMenu()
        setUpPanel()
        setUpStatusItem()
        setUpKeyMonitor()

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if let app, app.processIdentifier != getpid() { self?.lastExternalApp = app }
            }
        }

        // ⌘⇧Space: works even before Accessibility is granted.
        hotKeys.append(HotKey(keyCode: kVK_Space, modifiers: cmdKey | shiftKey, id: 1) { [weak self] in
            self?.togglePanel(focusComposer: true)
        })
        shiftMonitor.onLeftDouble = { [weak self] in self?.captureSelection() }
        shiftMonitor.onRightDouble = { [weak self] in self?.togglePanel(focusComposer: true) }
        startShiftMonitor()
        SelectionCapture.clipboard.start()

        #if DEBUG
        scheduleDebugSnapshots()
        #endif

        if !UserDefaults.standard.bool(forKey: "launchedBefore") {
            UserDefaults.standard.set(true, forKey: "launchedBefore")
            showPanel(focusComposer: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.saveNow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel(focusComposer: true)
        return false
    }

    // MARK: - Setup

    private func setUpMainMenu() {
        // Accessory apps never show the menu bar, but key equivalents (⌘C/⌘V in text fields) still route through it.
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(withTitle: "Close", action: #selector(hidePanelAction), keyEquivalent: "w").target = self
        appMenu.addItem(withTitle: "Quit Chat Todos", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    private func setUpPanel() {
        store.onHide = { [weak self] in self?.hidePanel() }
        store.onBlur = { [weak self] in _ = self?.panel.makeFirstResponder(nil) }
        store.onOpenSettings = { [weak self] in self?.showSettings() }
        panel.contentView = NSHostingView(rootView: RootView(store: store, settings: settings))
        if !panel.setFrameUsingName("ChatTodosPanel"), let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let height = min(680, frame.height - 40)
            panel.setFrame(NSRect(x: frame.maxX - 420, y: frame.maxY - height - 20, width: 400, height: height), display: false)
        }
        panel.setFrameAutosaveName("ChatTodosPanel")
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "Chat Todos")
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    private func setUpKeyMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.window === self.panel else { return event }
                return self.handleKey(event) ? nil : event
            }
        }
    }

    private func startShiftMonitor() {
        let options = ["AXTrustedCheckOptionPrompt": !UserDefaults.standard.bool(forKey: "promptedAccessibility")] as CFDictionary
        UserDefaults.standard.set(true, forKey: "promptedAccessibility")
        let trusted = AXIsProcessTrustedWithOptions(options)
        store.hasAccessibility = trusted
        if trusted && shiftMonitor.start() { return }

        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                let ok = AXIsProcessTrusted()
                self.store.hasAccessibility = ok
                if ok && self.shiftMonitor.start() { timer.invalidate() }
            }
        }
    }

    // MARK: - Panel

    func togglePanel(focusComposer: Bool = false) {
        if panel.isVisible && panel.isKeyWindow {
            hidePanel()
        } else {
            showPanel(focusComposer: focusComposer)
        }
    }

    func showPanel(focusComposer: Bool = false) {
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() {
            lastExternalApp = front
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        if focusComposer { store.focusComposer() }
    }

    func hidePanel() {
        store.showSwitcher = false
        store.showHelp = false
        store.editingID = nil
        panel.orderOut(nil)
        // Hand focus back to whatever you were working in.
        if let app = lastExternalApp, !app.isTerminated {
            app.activate()
        } else {
            NSApp.hide(nil)
        }
    }

    @objc private func hidePanelAction() {
        if settingsWindow.isKey { settingsWindow.close() } else { hidePanel() }
    }

    @objc func showSettings() { settingsWindow.show() }

    // MARK: - Capture

    private func captureSelection() {
        let front = NSWorkspace.shared.frontmostApplication
        guard front?.processIdentifier != getpid() else { return }
        let source = front?.localizedName
        Task { @MainActor in
            let text = await SelectionCapture.capture()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else {
                toast.show(title: "Nothing selected", subtitle: "Select or copy some text, then tap ⇧ twice.", success: false)
                return
            }
            store.capture(text, source: source)
            toast.show(title: "Saved to \(store.activeSection.name)", subtitle: text)
        }
    }

    // MARK: - Keyboard

    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = flags.contains(.command)
        let shift = flags.contains(.shift)
        let option = flags.contains(.option)
        let control = flags.contains(.control)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let editingText = panel.firstResponder is NSTextView

        if cmd && key == "k" { store.showSwitcher ? (store.showSwitcher = false) : store.openSwitcher(); return true }
        if cmd && key == "f" { store.toggleSearch(); return true }
        if cmd && key == "/" { store.showHelp.toggle(); return true }
        if event.keyCode == 53 { handleEscape(editingText: editingText); return true }

        if store.showSwitcher {
            switch event.keyCode {
            case 125: store.moveSwitcher(1); return true
            case 126: store.moveSwitcher(-1); return true
            default: return false
            }
        }
        if store.showHelp {
            store.showHelp = false
            return true
        }

        if editingText {
            if store.composerFocused && store.draft.isEmpty && event.keyCode == 126 && !cmd {
                panel.makeFirstResponder(nil)
                store.selectLast()
                return true
            }
            if store.searchFocused && (event.keyCode == 125 || event.keyCode == 36) {
                panel.makeFirstResponder(nil)
                store.selectFirst()
                return true
            }
            return false
        }

        let selected = store.selectedIDs
        switch event.keyCode {
        case 125, 126:
            let delta = event.keyCode == 125 ? 1 : -1
            if option { store.moveSelectedItem(by: delta); return true }
            if !store.moveCursor(delta, extend: shift) {
                store.clearSelection()
                store.focusComposer()
            }
            return true
        case 49:
            store.toggleDone(selected)
            return true
        case 36, 76:
            if cmd { store.copyAndComplete(selected) } else { store.beginEdit() }
            return true
        case 51, 117:
            store.delete(selected)
            return true
        case 48:
            store.focusComposer()
            return true
        default:
            break
        }

        if cmd {
            switch key {
            case "c": shift ? store.copyAsList(selected) : store.copy(selected)
            case "a": store.selectAll()
            case "z": store.undo()
            case "v": store.paste()
            case "e": store.exportMarkdown()
            default: return false
            }
            return true
        }
        if control || option { return false }

        if !selected.isEmpty, key.count == 1, let digit = Int(key), (0...TagColor.allCases.count).contains(digit) {
            store.setTag(digit == 0 ? nil : TagColor.allCases[digit - 1], for: selected)
            return true
        }

        // Any other printable key starts a new entry.
        if let chars = event.characters, !chars.isEmpty,
           chars.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0xF700 && $0.value != 0x7F }) {
            store.clearSelection()
            store.draft += chars
            store.focusComposer()
            return true
        }
        return false
    }

    private func handleEscape(editingText: Bool) {
        if store.showSwitcher { store.showSwitcher = false; return }
        if store.showHelp { store.showHelp = false; return }
        if store.editingID != nil {
            store.editingID = nil
            panel.makeFirstResponder(nil)
            return
        }
        if store.searchVisible && (store.searchFocused || !store.search.isEmpty) {
            store.closeSearch()
            panel.makeFirstResponder(nil)
            return
        }
        hidePanel()
    }

    #if DEBUG
    /// CHAT_TODOS_SNAPSHOT=/path/prefix writes PNGs of the panel in a few states (development only).
    private func scheduleDebugSnapshots() {
        guard let prefix = ProcessInfo.processInfo.environment["CHAT_TODOS_SNAPSHOT"] else { return }
        let steps: [(String, () -> Void)] = [
            ("list", { [self] in
                showPanel()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
                    store.onBlur()
                    store.moveCursor(1)
                    store.moveCursor(1)
                }
            }),
            ("settings", { [self] in showSettings() }),
            ("help", { [self] in settingsWindow.close(); panel.makeKey(); store.showHelp = true }),
            ("switcher", { [self] in store.showHelp = false; store.openSwitcher(); store.switcherQuery = "Re" }),
            ("compose", { [self] in
                store.showSwitcher = false
                store.focusComposer()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
                    for char in "Smoke test" { postKey(String(char), code: 0) }
                    postKey("\r", code: 36)
                }
            }),
            ("keys", { [self] in
                postKey("", code: 126) // ↑ leaves the empty composer and selects the last item
                postKey(" ", code: 49) // space checks it off
            }),
            ("empty", { [self] in store.showSwitcher = false; store.switchOrCreateSection("Fresh"); store.deleteSection(store.db.sections[0].id); store.deleteSection(store.db.sections[0].id) }),
        ]
        func postKey(_ chars: String, code: UInt16) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                                windowNumber: panel.windowNumber, context: nil, characters: chars,
                                                charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
        }
        for (index, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 + Double(index) * 1.2) { [self] in
                step.1()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in
                    guard let view = NSApp.keyWindow?.contentView ?? panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(prefix)-\(step.0).png"))
                }
            }
        }
    }
    #endif

    // MARK: - Status item menu

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            statusItem.menu = buildStatusMenu()
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            togglePanel(focusComposer: true)
        }
    }

    private func buildStatusMenu() -> NSMenu {
        let menu = NSMenu()
        let toggle = menu.addItem(withTitle: panel.isVisible ? "Hide Chat Todos" : "Show Chat Todos",
                                  action: #selector(menuToggle), keyEquivalent: " ")
        toggle.keyEquivalentModifierMask = [.command, .shift]
        toggle.target = self
        menu.addItem(.separator())

        if store.hasAccessibility {
            let info = menu.addItem(withTitle: "Capture: select text, tap ⇧ twice", action: nil, keyEquivalent: "")
            info.isEnabled = false
        } else {
            menu.addItem(withTitle: "Grant Accessibility Access…", action: #selector(openAccessibilitySettings), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: "Export as Markdown…", action: #selector(menuExport), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Show Data in Finder", action: #selector(menuReveal), keyEquivalent: "").target = self

        let login = menu.addItem(withTitle: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Chat Todos", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    @objc private func menuToggle() { togglePanel(focusComposer: true) }
    @objc private func menuExport() { store.exportMarkdown() }
    @objc private func menuReveal() { store.revealData() }

    @objc func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = "\(error.localizedDescription)\n\nMove Chat Todos to /Applications and try again."
            alert.runModal()
        }
    }
}
