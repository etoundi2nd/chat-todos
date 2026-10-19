import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class Store: ObservableObject {
    struct Group: Identifiable {
        let section: Section
        let items: [Item]
        var id: UUID { section.id }
    }

    enum SwitcherOption: Equatable {
        case section(Section)
        case create(String)
    }

    @Published private(set) var db: Database

    // List state
    @Published var selection: Set<UUID> = []
    @Published var cursorID: UUID?
    @Published var editingID: UUID?
    @Published var scrollTarget: UUID?

    // Composer / search / overlays
    @Published var draft = ""
    @Published var composerFocused = false
    @Published var composerFocusRequest = 0
    @Published var search = ""
    @Published var searchVisible = false
    @Published var searchFocused = false
    @Published var tagFilter: TagColor?
    @Published var hideDone: Bool { didSet { UserDefaults.standard.set(hideDone, forKey: "hideDone") } }
    @Published var showSwitcher = false
    @Published var switcherQuery = "" { didSet { switcherIndex = 0 } }
    @Published var switcherIndex = 0
    @Published var showHelp = false
    @Published var banner: String?
    @Published var hasAccessibility = true

    /// Set by the app delegate.
    var onHide: () -> Void = {}
    var onBlur: () -> Void = {}
    var onOpenSettings: () -> Void = {}

    let directory: URL
    var dataURL: URL { directory.appendingPathComponent("chat-todos.json") }
    var imagesDir: URL { directory.appendingPathComponent("images", isDirectory: true) }

    private var anchorID: UUID?
    private var undoStack: [Database] = []
    private var saveWork: DispatchWorkItem?
    private var bannerToken = 0
    private let imageCache = NSCache<NSString, NSImage>()

    nonisolated static var defaultDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["CHAT_TODOS_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Chat Todos", isDirectory: true)
    }

    init(directory: URL = Store.defaultDirectory) {
        self.directory = directory
        self.hideDone = UserDefaults.standard.bool(forKey: "hideDone")
        self.db = Store.load(from: directory.appendingPathComponent("chat-todos.json"))
        normalize()
        removeOrphanImages()
    }

    // MARK: - Persistence

    nonisolated(unsafe) private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func load(from url: URL) -> Database {
        guard let data = try? Data(contentsOf: url) else { return .fresh() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            guard let date = Store.dateFormatter.date(from: string) ?? ISO8601DateFormatter().date(from: string) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(string)"))
            }
            return date
        }
        if let db = try? decoder.decode(Database.self, from: data) { return db }
        // Never silently overwrite a file we can't read: keep a copy next to it.
        let stamp = Int(Date().timeIntervalSince1970)
        let backup = url.deletingPathExtension().appendingPathExtension("corrupt-\(stamp).json")
        try? FileManager.default.copyItem(at: url, to: backup)
        return .fresh()
    }

    private func normalize() {
        if db.sections.isEmpty { db.sections = [Section(name: "Inbox")] }
        if !db.sections.contains(where: { $0.id == db.activeSectionID }) {
            db.activeSectionID = db.sections[0].id
        }
        let ids = Set(db.sections.map(\.id))
        db.items = db.items.map { item in
            var item = item
            if !ids.contains(item.sectionID) { item.sectionID = db.sections[0].id }
            return item
        }
    }

    private func removeOrphanImages() {
        let used = Set(db.items.compactMap(\.imageFile))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: imagesDir.path)) ?? []
        for file in files where !used.contains(file) {
            try? FileManager.default.removeItem(at: imagesDir.appendingPathComponent(file))
        }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .custom { date, encoder in
                var container = encoder.singleValueContainer()
                try container.encode(Store.dateFormatter.string(from: date))
            }
            try encoder.encode(db).write(to: dataURL, options: .atomic)
        } catch {
            flash("Couldn't save: \(error.localizedDescription)")
        }
    }

    private func mutate(_ body: (inout Database) -> Void) {
        let before = db
        body(&db)
        guard db != before else { return }
        undoStack.append(before)
        if undoStack.count > 100 { undoStack.removeFirst() }
        scheduleSave()
    }

    func undo() {
        guard let previous = undoStack.popLast() else {
            flash("Nothing to undo")
            return
        }
        db = previous
        normalize()
        let ids = Set(db.items.map(\.id))
        selection = selection.filter(ids.contains)
        if let id = editingID, !ids.contains(id) { editingID = nil }
        scheduleSave()
    }

    // MARK: - Derived state

    var activeSection: Section {
        db.sections.first { $0.id == db.activeSectionID } ?? db.sections[0]
    }

    var isFiltering: Bool {
        tagFilter != nil || !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var groups: [Group] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtering = isFiltering
        return db.sections.compactMap { section in
            var items = db.items.filter { $0.sectionID == section.id }
            if hideDone { items = items.filter { !$0.done } }
            if let tag = tagFilter { items = items.filter { $0.tag == tag } }
            if !query.isEmpty {
                items = items.filter {
                    $0.text.lowercased().contains(query) || ($0.source?.lowercased().contains(query) ?? false)
                }
            }
            if filtering && items.isEmpty { return nil }
            return Group(section: section, items: items)
        }
    }

    var visibleItems: [Item] {
        let filtering = isFiltering
        return groups.flatMap { $0.section.collapsed && !filtering ? [] : $0.items }
    }

    /// Selected IDs in on-screen order.
    var selectedIDs: [UUID] {
        visibleItems.map(\.id).filter(selection.contains)
    }

    func item(_ id: UUID) -> Item? { db.items.first { $0.id == id } }

    // MARK: - Adding

    /// Returns the section name if `text` is a `# Name` / `## Name` command.
    static func sectionCommand(_ text: String) -> String? {
        guard !text.contains("\n") else { return nil }
        var rest = Substring(text)
        var hashes = 0
        while rest.first == "#" {
            hashes += 1
            rest = rest.dropFirst()
        }
        guard (1...2).contains(hashes), rest.first == " " else { return nil }
        let name = rest.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    static func isLink(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains(where: \.isWhitespace),
              let url = URL(string: t), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host != nil
        else { return false }
        return true
    }

    func submitDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        if let name = Store.sectionCommand(text) {
            switchOrCreateSection(name)
        } else {
            append(Item(text: text, kind: Store.isLink(text) ? .link : .prompt, sectionID: activeSection.id))
        }
    }

    /// Adds text captured from another app.
    @discardableResult
    func capture(_ text: String, source: String?) -> Item {
        let item = Item(text: text, kind: Store.isLink(text) ? .link : .note, sectionID: activeSection.id, source: source)
        append(item)
        return item
    }

    private func append(_ item: Item) {
        mutate { db in
            db.items.append(item)
            if let i = db.sections.firstIndex(where: { $0.id == item.sectionID }) {
                db.sections[i].collapsed = false
            }
        }
        scrollTarget = item.id
    }

    func addImage(_ image: NSImage, source: String? = nil) {
        guard let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return flash("Couldn't read image") }
        let name = UUID().uuidString + ".png"
        do {
            try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
            try png.write(to: imagesDir.appendingPathComponent(name))
            append(Item(text: "", kind: .image, sectionID: activeSection.id, source: source, imageFile: name))
        } catch {
            flash("Couldn't save image")
        }
    }

    func addFile(_ url: URL, source: String? = nil) {
        let type = UTType(filenameExtension: url.pathExtension)
        if let type, type.conforms(to: .image) {
            let name = UUID().uuidString + "." + url.pathExtension.lowercased()
            do {
                try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: url, to: imagesDir.appendingPathComponent(name))
                append(Item(text: url.lastPathComponent, kind: .image, sectionID: activeSection.id, source: source, imageFile: name))
            } catch {
                flash("Couldn't add \(url.lastPathComponent)")
            }
        } else if let type, type.conforms(to: .text),
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 200_000,
                  let text = try? String(contentsOf: url, encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            append(Item(text: text.trimmingCharacters(in: .whitespacesAndNewlines), kind: .note, sectionID: activeSection.id, source: url.lastPathComponent))
        } else {
            append(Item(text: url.path, kind: .file, sectionID: activeSection.id, source: source))
        }
    }

    /// ⌘V in the list: files, then images, then text.
    func paste() {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            urls.forEach { addFile($0) }
        } else if pb.string(forType: .string) == nil, let image = NSImage(pasteboard: pb) {
            addImage(image)
        } else if let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            append(Item(text: text, kind: Store.isLink(text) ? .link : .note, sectionID: activeSection.id))
        }
    }

    func handleDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in self.addFile(url) }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                _ = provider.loadObject(ofClass: NSImage.self) { image, _ in
                    guard let image = image as? NSImage else { return }
                    Task { @MainActor in self.addImage(image) }
                }
            } else if provider.canLoadObject(ofClass: String.self) {
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    guard let text, !text.isEmpty else { return }
                    Task { @MainActor in self.capture(text, source: nil) }
                }
            }
        }
    }

    // MARK: - Selection

    func select(_ id: UUID, extend: Bool = false, toggle: Bool = false) {
        if toggle {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            cursorID = id
            anchorID = id
            return
        }
        let ids = visibleItems.map(\.id)
        if extend, let anchor = anchorID, let a = ids.firstIndex(of: anchor), let b = ids.firstIndex(of: id) {
            selection = Set(ids[min(a, b)...max(a, b)])
            cursorID = id
            return
        }
        selection = [id]
        anchorID = id
        cursorID = id
    }

    /// Moves the keyboard cursor. Returns false when moving down past the last item.
    @discardableResult
    func moveCursor(_ delta: Int, extend: Bool = false) -> Bool {
        let ids = visibleItems.map(\.id)
        guard !ids.isEmpty else { return false }
        guard let cursor = cursorID, let i = ids.firstIndex(of: cursor), !selection.isEmpty else {
            let id = delta > 0 ? ids[0] : ids[ids.count - 1]
            select(id)
            scrollTarget = id
            return true
        }
        let j = i + delta
        if j >= ids.count { return false }
        let id = ids[max(0, j)]
        select(id, extend: extend)
        scrollTarget = id
        return true
    }

    func selectLast() {
        guard let last = visibleItems.last else { return }
        select(last.id)
        scrollTarget = last.id
    }

    func selectFirst() {
        guard let first = visibleItems.first else { return }
        select(first.id)
        scrollTarget = first.id
    }

    func selectAll() {
        selection = Set(visibleItems.map(\.id))
    }

    func clearSelection() {
        selection = []
        cursorID = nil
        anchorID = nil
    }

    // MARK: - Item actions

    func toggleDone(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let set = Set(ids)
        let markDone = db.items.contains { set.contains($0.id) && !$0.done }
        mutate { db in
            for i in db.items.indices where set.contains(db.items[i].id) {
                db.items[i].done = markDone
                db.items[i].doneAt = markDone ? Date() : nil
            }
        }
    }

    func delete(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let set = Set(ids)
        let visible = visibleItems.map(\.id)
        // Keep the cursor near where it was.
        let next = visible.drop(while: { !set.contains($0) }).first { !set.contains($0) }
            ?? visible.last { !set.contains($0) }
        mutate { $0.items.removeAll { set.contains($0.id) } }
        if let next { select(next) } else { clearSelection() }
        flash(ids.count == 1 ? "Deleted · ⌘Z to undo" : "Deleted \(ids.count) items · ⌘Z to undo")
    }

    func setTag(_ tag: TagColor?, for ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let set = Set(ids)
        let alreadyAll = tag != nil && db.items.filter { set.contains($0.id) }.allSatisfy { $0.tag == tag }
        mutate { db in
            for i in db.items.indices where set.contains(db.items[i].id) {
                db.items[i].tag = alreadyAll ? nil : tag
            }
        }
    }

    func beginEdit(_ id: UUID? = nil) {
        guard let id = id ?? cursorID ?? selectedIDs.first, let item = item(id) else { return }
        switch item.kind {
        case .image:
            copy([id])
        case .file:
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.text)])
        default:
            select(id)
            editingID = id
        }
    }

    func commitEdit(_ id: UUID, text: String) {
        guard editingID == id else { return }
        editingID = nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            delete([id])
            return
        }
        mutate { db in
            guard let i = db.items.firstIndex(where: { $0.id == id }) else { return }
            db.items[i].text = trimmed
            if db.items[i].kind == .link || db.items[i].kind == .note || db.items[i].kind == .prompt {
                if Store.isLink(trimmed) { db.items[i].kind = .link }
                else if db.items[i].kind == .link { db.items[i].kind = .note }
            }
        }
    }

    func move(_ ids: [UUID], to sectionID: UUID) {
        let set = Set(ids)
        mutate { db in
            for i in db.items.indices where set.contains(db.items[i].id) {
                db.items[i].sectionID = sectionID
            }
        }
    }

    /// ⌥↑ / ⌥↓: reorder the selected item within its section.
    func moveSelectedItem(by delta: Int) {
        guard let id = cursorID, let item = item(id) else { return }
        let siblings = db.items.indices.filter { db.items[$0].sectionID == item.sectionID }
        guard let pos = siblings.firstIndex(where: { db.items[$0].id == id }) else { return }
        let target = pos + delta
        guard siblings.indices.contains(target) else { return }
        mutate { $0.items.swapAt(siblings[pos], siblings[target]) }
        scrollTarget = id
    }

    func clearCompleted(in sectionID: UUID? = nil) {
        let count = db.items.filter { $0.done && (sectionID == nil || $0.sectionID == sectionID) }.count
        guard count > 0 else { return flash("No completed items") }
        mutate { $0.items.removeAll { $0.done && (sectionID == nil || $0.sectionID == sectionID) } }
        flash("Cleared \(count) completed · ⌘Z to undo")
    }

    // MARK: - Clipboard

    static func copyText(for item: Item) -> String {
        item.text
    }

    func image(for item: Item) -> NSImage? {
        guard let file = item.imageFile else { return nil }
        if let cached = imageCache.object(forKey: file as NSString) { return cached }
        guard let image = NSImage(contentsOf: imagesDir.appendingPathComponent(file)) else { return nil }
        imageCache.setObject(image, forKey: file as NSString)
        return image
    }

    func copy(_ ids: [UUID]) {
        let items = ids.compactMap(item)
        guard !items.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        if items.count == 1, let image = image(for: items[0]) {
            pb.writeObjects([image])
            flash("Copied image")
            return
        }
        pb.setString(items.map(Store.copyText).joined(separator: "\n\n"), forType: .string)
        flash(items.count == 1 ? "Copied" : "Copied \(items.count) items")
    }

    func copyAsList(_ ids: [UUID]) {
        let items = ids.compactMap(item)
        guard !items.isEmpty else { return }
        let text = items.map { Store.listLine(for: $0, checkbox: false) }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        flash("Copied \(items.count) as list")
    }

    /// ⌘↩: copy a queued prompt and check it off in one go.
    func copyAndComplete(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        copy(ids)
        let set = Set(ids)
        mutate { db in
            for i in db.items.indices where set.contains(db.items[i].id) {
                db.items[i].done = true
                db.items[i].doneAt = Date()
            }
        }
        flash(ids.count == 1 ? "Copied & checked off" : "Copied & checked off \(ids.count)")
    }

    // MARK: - Sections

    func setActive(_ id: UUID) {
        mutate { db in
            db.activeSectionID = id
            if let i = db.sections.firstIndex(where: { $0.id == id }) { db.sections[i].collapsed = false }
        }
    }

    func switchOrCreateSection(_ name: String) {
        if let existing = db.sections.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            setActive(existing.id)
        } else {
            let section = Section(name: name)
            mutate { db in
                db.sections.append(section)
                db.activeSectionID = section.id
            }
        }
        flash("Capturing to \(activeSection.name)")
    }

    func renameSection(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        mutate { db in
            if let i = db.sections.firstIndex(where: { $0.id == id }) { db.sections[i].name = name }
        }
    }

    func deleteSection(_ id: UUID) {
        mutate { db in
            db.sections.removeAll { $0.id == id }
            db.items.removeAll { $0.sectionID == id }
            if db.sections.isEmpty { db.sections = [Section(name: "Inbox")] }
            if !db.sections.contains(where: { $0.id == db.activeSectionID }) {
                db.activeSectionID = db.sections[db.sections.count - 1].id
            }
        }
        flash("Section deleted · ⌘Z to undo")
    }

    func toggleCollapsed(_ id: UUID) {
        mutate { db in
            if let i = db.sections.firstIndex(where: { $0.id == id }) { db.sections[i].collapsed.toggle() }
        }
    }

    func promptRename(_ section: Section) {
        let alert = NSAlert()
        alert.messageText = "Rename Section"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: section.name)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            renameSection(section.id, to: field.stringValue)
        }
    }

    // MARK: - Switcher (⌘K)

    var switcherOptions: [SwitcherOption] {
        let query = switcherQuery.trimmingCharacters(in: .whitespaces)
        let matches = db.sections.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
        var options = matches.map(SwitcherOption.section)
        if !query.isEmpty, !db.sections.contains(where: { $0.name.caseInsensitiveCompare(query) == .orderedSame }) {
            options.append(.create(query))
        }
        return options
    }

    func openSwitcher() {
        switcherQuery = ""
        switcherIndex = 0
        showHelp = false
        showSwitcher = true
    }

    func moveSwitcher(_ delta: Int) {
        let count = switcherOptions.count
        guard count > 0 else { return }
        switcherIndex = (switcherIndex + delta + count) % count
    }

    func chooseSwitcher(_ option: SwitcherOption? = nil) {
        let options = switcherOptions
        guard let option = option ?? (options.indices.contains(switcherIndex) ? options[switcherIndex] : nil) else { return }
        showSwitcher = false
        switch option {
        case .section(let section):
            setActive(section.id)
            flash("Capturing to \(section.name)")
        case .create(let name):
            switchOrCreateSection(name)
        }
    }

    // MARK: - Search, focus, banner

    func toggleSearch() {
        if searchVisible { closeSearch() } else { searchVisible = true }
    }

    func closeSearch() {
        searchVisible = false
        search = ""
    }

    func focusComposer() {
        composerFocusRequest += 1
    }

    func flash(_ message: String) {
        bannerToken += 1
        let token = bannerToken
        withAnimation(.easeOut(duration: 0.15)) { banner = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.bannerToken == token else { return }
                withAnimation(.easeIn(duration: 0.2)) { self.banner = nil }
            }
        }
    }

    // MARK: - Export

    static func listLine(for item: Item, checkbox: Bool, imagesDir: URL? = nil) -> String {
        let body: String
        switch item.kind {
        case .image:
            let path = imagesDir.map { $0.appendingPathComponent(item.imageFile ?? "").absoluteString } ?? (item.imageFile ?? "")
            body = "![\(item.text)](\(path))"
        case .file:
            body = "[\(URL(fileURLWithPath: item.text).lastPathComponent)](\(URL(fileURLWithPath: item.text).absoluteString))"
        default:
            body = item.text
        }
        let lines = body.components(separatedBy: "\n")
        let prefix = checkbox ? "- [\(item.done ? "x" : " ")] " : "- "
        return ([prefix + lines[0]] + lines.dropFirst().map { "  " + $0 }).joined(separator: "\n")
    }

    func markdown() -> String {
        var out = "# Chat Todos\n"
        for section in db.sections {
            let items = db.items.filter { $0.sectionID == section.id }
            guard !items.isEmpty else { continue }
            out += "\n## \(section.name)\n\n"
            out += items.map { Store.listLine(for: $0, checkbox: true, imagesDir: imagesDir) }.joined(separator: "\n")
            out += "\n"
        }
        return out
    }

    func exportMarkdown() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Chat Todos.md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try markdown().write(to: url, atomically: true, encoding: .utf8)
            flash("Exported to \(url.lastPathComponent)")
        } catch {
            flash("Export failed")
        }
    }

    func revealData() {
        saveNow()
        NSWorkspace.shared.activateFileViewerSelecting([dataURL])
    }
}
