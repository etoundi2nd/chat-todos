import XCTest
@testable import ChatTodos

@MainActor
final class StoreTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("chat-todos-tests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testSectionCommandParsing() {
        XCTAssertEqual(Store.sectionCommand("# Research"), "Research")
        XCTAssertEqual(Store.sectionCommand("## Bug bash  "), "Bug bash")
        XCTAssertNil(Store.sectionCommand("#hashtag"))
        XCTAssertNil(Store.sectionCommand("### too deep"))
        XCTAssertNil(Store.sectionCommand("# "))
        XCTAssertNil(Store.sectionCommand("# two\nlines"))
    }

    func testLinkDetection() {
        XCTAssertTrue(Store.isLink("https://shadcn.com"))
        XCTAssertTrue(Store.isLink("  http://example.com/a?b=c  "))
        XCTAssertFalse(Store.isLink("see https://example.com"))
        XCTAssertFalse(Store.isLink("ftp://example.com"))
        XCTAssertFalse(Store.isLink("not a link"))
    }

    func testDraftAddsPromptOrSwitchesSection() {
        let store = Store(directory: dir)
        store.draft = "Explain this stack trace"
        store.submitDraft()
        XCTAssertEqual(store.db.items.last?.kind, .prompt)
        XCTAssertEqual(store.draft, "")

        store.draft = "# Research"
        store.submitDraft()
        XCTAssertEqual(store.activeSection.name, "Research")
        XCTAssertEqual(store.db.sections.count, 2)

        store.draft = "# inbox"
        store.submitDraft()
        XCTAssertEqual(store.activeSection.name, "Inbox", "existing sections match case-insensitively")
        XCTAssertEqual(store.db.sections.count, 2)
    }

    func testCaptureGoesToActiveSection() {
        let store = Store(directory: dir)
        store.switchOrCreateSection("Work")
        let item = store.capture("const x = 1", source: "Cursor")
        XCTAssertEqual(item.sectionID, store.activeSection.id)
        XCTAssertEqual(item.kind, .note)
        XCTAssertEqual(store.capture("https://claude.ai", source: nil).kind, .link)
    }

    func testToggleDeleteAndUndo() {
        let store = Store(directory: dir)
        let a = store.capture("a", source: nil)
        let b = store.capture("b", source: nil)
        store.toggleDone([a.id, b.id])
        XCTAssertTrue(store.db.items.allSatisfy(\.done))
        store.toggleDone([a.id, b.id])
        XCTAssertFalse(store.db.items.contains(where: \.done))

        store.delete([a.id])
        XCTAssertEqual(store.db.items.map(\.text), ["b"])
        store.undo()
        XCTAssertEqual(store.db.items.map(\.text), ["a", "b"])
    }

    func testTagTogglesOff() {
        let store = Store(directory: dir)
        let a = store.capture("a", source: nil)
        store.setTag(.red, for: [a.id])
        XCTAssertEqual(store.item(a.id)?.tag, .red)
        store.setTag(.red, for: [a.id])
        XCTAssertNil(store.item(a.id)?.tag)
    }

    func testSelectionAndMoveCursor() {
        let store = Store(directory: dir)
        let items = ["1", "2", "3"].map { store.capture($0, source: nil) }
        XCTAssertTrue(store.moveCursor(1))
        XCTAssertEqual(store.selectedIDs, [items[0].id])
        store.moveCursor(1, extend: true)
        XCTAssertEqual(store.selectedIDs, [items[0].id, items[1].id])
        store.moveCursor(1)
        XCTAssertFalse(store.moveCursor(1), "moving past the end hands off to the composer")
    }

    func testFilteringHidesCollapsedAndDone() {
        let store = Store(directory: dir)
        let a = store.capture("alpha", source: "Safari")
        _ = store.capture("beta", source: nil)
        store.toggleDone([a.id])
        store.hideDone = true
        XCTAssertEqual(store.visibleItems.map(\.text), ["beta"])
        store.hideDone = false
        store.search = "safari"
        XCTAssertEqual(store.visibleItems.map(\.text), ["alpha"])
        store.search = ""
        store.toggleCollapsed(store.activeSection.id)
        XCTAssertTrue(store.visibleItems.isEmpty)
    }

    func testPersistenceRoundTrip() throws {
        let store = Store(directory: dir)
        store.switchOrCreateSection("Prompts")
        let item = store.capture("multi\nline", source: "ChatGPT")
        store.setTag(.blue, for: [item.id])
        store.saveNow()

        let reloaded = Store(directory: dir)
        XCTAssertEqual(reloaded.db.sections.map(\.name), ["Inbox", "Prompts"])
        XCTAssertEqual(reloaded.activeSection.name, "Prompts")
        let copy = try XCTUnwrap(reloaded.db.items.first)
        XCTAssertEqual(copy.id, item.id)
        XCTAssertEqual(copy.text, "multi\nline")
        XCTAssertEqual(copy.tag, .blue)
        XCTAssertEqual(copy.source, "ChatGPT")
        XCTAssertEqual(copy.createdAt.timeIntervalSince1970, item.createdAt.timeIntervalSince1970, accuracy: 0.001)
    }

    func testCorruptFileIsBackedUp() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("chat-todos.json"))
        let store = Store(directory: dir)
        XCTAssertEqual(store.db.sections.map(\.name), ["Inbox"])
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(files.contains { $0.contains("corrupt") })
    }

    func testMarkdownExport() {
        let store = Store(directory: dir)
        let a = store.capture("first\nsecond", source: nil)
        store.toggleDone([a.id])
        store.draft = "next prompt"
        store.submitDraft()
        XCTAssertEqual(store.markdown(), "# Chat Todos\n\n## Inbox\n\n- [x] first\n  second\n- [ ] next prompt\n")
    }
}
