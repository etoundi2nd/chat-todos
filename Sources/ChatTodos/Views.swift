import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @ObservedObject var store: Store
    @ObservedObject var settings: AppSettings
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(store: store)
            if !store.hasAccessibility { PermissionBanner() }
            if store.searchVisible { SearchBar(store: store) }
            Divider().opacity(0.6)
            ItemListView(store: store)
            ComposerView(store: store)
        }
        .frame(minWidth: 320, minHeight: 360)
        .background(VisualEffectBackground(material: .popover))
        .overlay {
            if store.showSwitcher {
                SwitcherView(store: store)
            } else if store.showHelp {
                HelpView { store.showHelp = false }
            }
        }
        .overlay(alignment: .bottom) {
            if let banner = store.banner {
                Text(banner)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.thickMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                    .padding(.bottom, 84)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .environment(\.typography, settings.typography)
        .onDrop(of: [.fileURL, .image, .plainText], isTargeted: $dropTargeted) { providers in
            store.handleDrop(providers)
            return true
        }
        .ignoresSafeArea()
    }
}

// MARK: - Header

struct HeaderView: View {
    @ObservedObject var store: Store

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(store.db.sections) { section in
                    Button {
                        store.setActive(section.id)
                    } label: {
                        if section.id == store.activeSection.id {
                            Label(section.name, systemImage: "checkmark")
                        } else {
                            Text(section.name)
                        }
                    }
                }
                Divider()
                Button("Switch or Create Section…  ⌘K") { store.openSwitcher() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "checklist")
                    Text(store.activeSection.name)
                }
                .font(.system(size: 13, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("New items go to this section")

            Spacer(minLength: 4)

            HStack(spacing: 5) {
                ForEach(TagColor.allCases) { tag in
                    Circle()
                        .fill(tag.color.opacity(store.tagFilter == nil || store.tagFilter == tag ? 1 : 0.3))
                        .frame(width: 9, height: 9)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(store.tagFilter == tag ? 0.6 : 0), lineWidth: 1.5).padding(-2.5))
                        .contentShape(Rectangle().inset(by: -3))
                        .onTapGesture { store.tagFilter = store.tagFilter == tag ? nil : tag }
                        .help("Show \(tag.rawValue) items")
                }
            }

            Button { store.toggleSearch() } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.plain)
            .foregroundStyle(store.searchVisible ? Color.accentColor : .secondary)
            .help("Search (⌘F)")

            Menu {
                Toggle("Hide Completed", isOn: $store.hideDone)
                Button("Clear Completed") { store.clearCompleted() }
                Divider()
                Button("Export as Markdown…") { store.exportMarkdown() }
                Button("Show Data in Finder") { store.revealData() }
                Divider()
                Button("Settings…  ⌘,") { store.onOpenSettings() }
                Button("Keyboard Shortcuts  ⌘/") { store.showHelp = true }
                Button("Hide Panel  esc") { store.onHide() }
                Button("Quit Chat Todos") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 9)
    }
}

struct PermissionBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Allow Accessibility access to capture with ⇧⇧ from any app.")
                    .font(.system(size: 11.5))
                Text("Already on? Remove Chat Todos with − and add it again.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Open Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }
}

struct SearchBar: View {
    @ObservedObject var store: Store
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: $store.search)
                .textFieldStyle(.plain)
                .focused($focused)
            if !store.search.isEmpty {
                Button { store.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .onAppear { focused = true }
        .onChange(of: focused) { _, value in store.searchFocused = value }
        .onDisappear { store.searchFocused = false }
    }
}

// MARK: - List

struct ItemListView: View {
    @ObservedObject var store: Store

    var body: some View {
        let groups = store.groups
        let showHeaders = store.db.sections.count > 1 || store.isFiltering
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(groups) { group in
                        let collapsed = group.section.collapsed && !store.isFiltering
                        if showHeaders {
                            SectionHeaderView(store: store, group: group, collapsed: collapsed)
                        }
                        if !collapsed {
                            ForEach(group.items) { item in
                                ItemRow(store: store, item: item).id(item.id)
                            }
                            if group.items.isEmpty && showHeaders {
                                Text(group.section.id == store.activeSection.id ? "New items land here" : "Empty")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .overlay {
                if store.db.items.isEmpty {
                    EmptyStateView()
                } else if store.isFiltering && groups.isEmpty {
                    Text("No matches").foregroundStyle(.secondary)
                }
            }
            .onChange(of: store.scrollTarget) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
                DispatchQueue.main.async { store.scrollTarget = nil }
            }
            .onAppear {
                if let last = store.visibleItems.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }
}

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "text.bubble")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            VStack(spacing: 4) {
                Text("Nothing here yet").font(.system(size: 13, weight: .semibold))
                Text("Things to keep and prompts to try next.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 7) {
                HintRow(keys: "⇧ ⇧", text: "Save selected text from any app")
                HintRow(keys: "⇧ ⇧ right", text: "Show or hide this panel")
                HintRow(keys: "⌘C", text: "Copy an item into ChatGPT, Claude, Cursor")
                HintRow(keys: "space", text: "Check it off")
                HintRow(keys: "# name", text: "Start a new section")
            }
            .padding(.top, 4)
        }
        .padding(24)
        .allowsHitTesting(false)
    }
}

struct HintRow: View {
    let keys: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Text(keys)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .frame(minWidth: 64)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07)))
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

struct SectionHeaderView: View {
    @Environment(\.typography) private var typography
    @ObservedObject var store: Store
    let group: Store.Group
    let collapsed: Bool

    var body: some View {
        let section = group.section
        let active = section.id == store.activeSection.id
        let open = group.items.filter { !$0.done }.count
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(typography.ui(9, weight: .bold))
                .rotationEffect(.degrees(collapsed ? 0 : 90))
                .foregroundStyle(.tertiary)
                .frame(width: 10)
            Text(section.name)
                .font(typography.ui(11, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(active ? .primary : .secondary)
            if active {
                Circle().fill(Color.accentColor).frame(width: 5, height: 5).help("New items go here")
            }
            if !group.items.isEmpty {
                Text("\(open)/\(group.items.count)")
                    .font(typography.ui(10.5).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .contentShape(Rectangle())
        .onTapGesture { store.toggleCollapsed(section.id) }
        .contextMenu {
            Button("Add New Items Here") { store.setActive(section.id) }.disabled(active)
            Button("Rename…") { store.promptRename(section) }
            Button("Clear Completed") { store.clearCompleted(in: section.id) }
            Divider()
            Button("Delete Section", role: .destructive) { store.deleteSection(section.id) }
        }
    }
}

struct ItemRow: View {
    @Environment(\.typography) private var typography
    @ObservedObject var store: Store
    let item: Item
    @State private var hovering = false
    @State private var editText = ""
    @FocusState private var editFocused: Bool

    private var selected: Bool { store.selection.contains(item.id) }
    private var editing: Bool { store.editingID == item.id }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Button { store.toggleDone([item.id]) } label: {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(typography.ui(15))
                    .foregroundStyle(item.done ? Color.accentColor : Color.secondary.opacity(0.7))
            }
            .buttonStyle(.plain)
            .padding(.top, 0.5)

            VStack(alignment: .leading, spacing: 3) {
                content
                meta
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if hovering && !editing {
                Button { store.copy([item.id]) } label: {
                    Image(systemName: "doc.on.doc").font(typography.ui(11.5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Copy (⌘C)")
                .padding(.top, 2)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.16) : hovering ? Color.primary.opacity(0.045) : .clear)
        )
        .overlay(alignment: .leading) {
            if let tag = item.tag {
                Capsule().fill(tag.color).frame(width: 3).padding(.vertical, 7)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { click() }
        .contextMenu { menu }
    }

    @ViewBuilder private var content: some View {
        if editing {
            TextField("", text: $editText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(typography.text())
                .focused($editFocused)
                .onAppear {
                    editText = item.text
                    DispatchQueue.main.async { editFocused = true }
                }
                .onSubmit { store.commitEdit(item.id, text: editText) }
                .onChange(of: editFocused) { _, focused in
                    if !focused { store.commitEdit(item.id, text: editText) }
                }
        } else {
            switch item.kind {
            case .image:
                if let image = store.image(for: item) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 280, maxHeight: 170, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .opacity(item.done ? 0.5 : 1)
                } else {
                    Label("Missing image", systemImage: "photo").foregroundStyle(.secondary).font(typography.text())
                }
            case .file:
                Label(URL(fileURLWithPath: item.text).lastPathComponent, systemImage: "doc")
                    .font(typography.text())
                    .strikethrough(item.done)
            case .link:
                Text(item.text)
                    .font(typography.text())
                    .foregroundStyle(item.done ? Color.secondary : Color.accentColor)
                    .strikethrough(item.done)
                    .lineLimit(2)
                    .truncationMode(.middle)
            case .note, .prompt:
                MarkdownText(text: item.text, done: item.done, collapsed: !selected)
                    .font(typography.text())
            }
        }
    }

    private var meta: some View {
        HStack(spacing: 4) {
            Image(systemName: Self.icon(for: item.kind))
            if let source = item.source {
                Text(source)
                Text("·")
            }
            if Date().timeIntervalSince(item.createdAt) < 60 {
                Text("just now")
            } else {
                Text(item.createdAt, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
            }
        }
        .font(typography.ui(10.5))
        .foregroundStyle(.tertiary)
        .lineLimit(1)
    }

    @ViewBuilder private var menu: some View {
        let ids = selected ? store.selectedIDs : [item.id]
        Button("Copy") { store.copy(ids) }
        Button("Copy & Check Off") { store.copyAndComplete(ids) }
        if ids.count > 1 { Button("Copy as List") { store.copyAsList(ids) } }
        if item.kind == .link, let url = URL(string: item.text) {
            Button("Open Link") { NSWorkspace.shared.open(url) }
        }
        if item.kind == .file {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.text)]) }
        }
        Divider()
        Button(item.done ? "Mark as Not Done" : "Mark as Done") { store.toggleDone(ids) }
        if item.kind != .image && item.kind != .file {
            Button("Edit") { store.beginEdit(item.id) }
        }
        Menu("Tag") {
            ForEach(TagColor.allCases) { tag in
                Button("\(tag.rawValue.capitalized)  \(tag.shortcut)") { store.setTag(tag, for: ids) }
            }
            Divider()
            Button("None  0") { store.setTag(nil, for: ids) }
        }
        if store.db.sections.count > 1 {
            Menu("Move to") {
                ForEach(store.db.sections.filter { $0.id != item.sectionID }) { section in
                    Button(section.name) { store.move(ids, to: section.id) }
                }
            }
        }
        Divider()
        Button("Delete", role: .destructive) { store.delete(ids) }
    }

    private func click() {
        let flags = NSEvent.modifierFlags
        if NSApp.currentEvent?.clickCount == 2 {
            if item.kind == .link, let url = URL(string: item.text) {
                NSWorkspace.shared.open(url)
            } else {
                store.beginEdit(item.id)
            }
            return
        }
        if store.editingID != nil && !editing { store.editingID = nil }
        store.onBlur()
        store.select(item.id, extend: flags.contains(.shift), toggle: flags.contains(.command))
    }

    static func icon(for kind: ItemKind) -> String {
        switch kind {
        case .note: "text.quote"
        case .prompt: "text.bubble"
        case .link: "link"
        case .image: "photo"
        case .file: "doc"
        }
    }
}

// MARK: - Composer

struct ComposerView: View {
    @Environment(\.typography) private var typography
    @ObservedObject var store: Store
    @FocusState private var focused: Bool

    private var isSectionCommand: Bool { store.draft.hasPrefix("# ") || store.draft.hasPrefix("## ") }
    private var isBlank: Bool { store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Queue a prompt, jot a note…", text: $store.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(typography.text())
                    .lineLimit(1...8)
                    .focused($focused)
                    .onSubmit {
                        store.submitDraft()
                        focused = true
                    }
                Button { store.submitDraft() } label: {
                    Image(systemName: isSectionCommand ? "folder.badge.plus" : "arrow.up.circle.fill")
                        .font(.system(size: 17))
                }
                .buttonStyle(.plain)
                .foregroundStyle(isBlank ? Color.secondary.opacity(0.4) : Color.accentColor)
                .disabled(isBlank)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(focused ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.08))
            )

            HStack(spacing: 4) {
                if isSectionCommand {
                    Text("↩ switch to or create this section")
                } else {
                    Text("↩ add to \(store.activeSection.name)")
                    Text("·")
                    Text("# new section")
                    Text("·")
                    Text("⌘/ shortcuts")
                }
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 4)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .onChange(of: store.composerFocusRequest) { _, _ in
            focused = true
            // Becoming first responder selects everything; put the caret at the end instead.
            DispatchQueue.main.async {
                if let view = NSApp.keyWindow?.firstResponder as? NSTextView {
                    view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
                }
            }
        }
        .onChange(of: focused) { _, value in
            store.composerFocused = value
            if value { store.clearSelection() }
        }
    }
}

// MARK: - Overlays

struct SwitcherView: View {
    @ObservedObject var store: Store
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.18)
                .onTapGesture { store.showSwitcher = false }
            VStack(alignment: .leading, spacing: 0) {
                TextField("Switch to or create a section…", text: $store.switcherQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .padding(12)
                    .focused($focused)
                    .onSubmit { store.chooseSwitcher() }
                Divider()
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(Array(store.switcherOptions.enumerated()), id: \.offset) { index, option in
                            row(option, highlighted: index == store.switcherIndex)
                                .onTapGesture { store.chooseSwitcher(option) }
                        }
                    }
                    .padding(5)
                }
                .frame(maxHeight: 260)
                .fixedSize(horizontal: false, vertical: true)
            }
            .background(VisualEffectBackground(material: .menu))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
            .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
            .padding(.horizontal, 18)
            .padding(.top, 48)
        }
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private func row(_ option: Store.SwitcherOption, highlighted: Bool) -> some View {
        HStack(spacing: 8) {
            switch option {
            case .section(let section):
                Image(systemName: "folder")
                Text(section.name)
                Spacer()
                if section.id == store.activeSection.id {
                    Text("current").foregroundStyle(.secondary).font(.system(size: 11))
                }
                Text("\(store.db.items.filter { $0.sectionID == section.id }.count)")
                    .foregroundStyle(.tertiary)
                    .font(.system(size: 11).monospacedDigit())
            case .create(let name):
                Image(systemName: "plus")
                Text("Create “\(name)”")
                Spacer()
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(highlighted ? Color.accentColor.opacity(0.2) : .clear))
        .contentShape(Rectangle())
    }
}

struct HelpView: View {
    let close: () -> Void

    private let rows: [(String, String)] = [
        ("⇧ ⇧", "Save selected text (any app)"),
        ("right ⇧ ⇧", "Show / hide Chat Todos"),
        ("⌘⇧Space", "Show / hide (fallback)"),
        ("↑ ↓", "Move · ⇧ to extend · ⌥ to reorder"),
        ("space", "Check off"),
        ("⌘C", "Copy · ⌘⇧C copy as list"),
        ("⌘↩", "Copy and check off"),
        ("↩", "Edit · double-click also works"),
        ("⌫", "Delete · ⌘Z undo"),
        ("1 – 6 · 0", "Color tag · clear tag"),
        ("⌘V", "Paste text, image, or file"),
        ("⌘K", "Switch or create section"),
        ("⌘F", "Search"),
        ("⌘E", "Export as Markdown"),
        ("tab · type", "Jump to composer"),
        ("esc", "Hide and return to your app"),
    ]

    var body: some View {
        ZStack {
            Color.black.opacity(0.18)
            VStack(alignment: .leading, spacing: 7) {
                Text("Keyboard Shortcuts").font(.system(size: 13, weight: .semibold)).padding(.bottom, 4)
                ForEach(rows, id: \.0) { keys, text in
                    HStack {
                        Text(keys)
                            .font(.system(size: 11.5, weight: .medium, design: .rounded))
                            .frame(width: 92, alignment: .leading)
                        Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(16)
            .background(VisualEffectBackground(material: .menu))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
            .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
            .padding(18)
        }
        .onTapGesture(perform: close)
    }
}
