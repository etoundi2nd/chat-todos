import XCTest
@testable import ChatTodos

final class MarkdownParserTests: XCTestCase {
    func testNestedListsFromClaudeCodeOutput() {
        let text = """
        1. The description says restart is not retried
           - What's wrong: RETRIED_EVENT_TYPES = %w[create restart]
           - Fix: update the description. Also list what it leaves out:
             - the workflow's skip rules are re-applied;
             - a retry waits for a working day.
        2. Second point
        """
        XCTAssertEqual(MarkdownParser.parse(text), [
            .listItem(level: 0, marker: .ordered("1."), text: "The description says restart is not retried"),
            .listItem(level: 1, marker: .bullet, text: "What's wrong: RETRIED_EVENT_TYPES = %w[create restart]"),
            .listItem(level: 1, marker: .bullet, text: "Fix: update the description. Also list what it leaves out:"),
            .listItem(level: 2, marker: .bullet, text: "the workflow's skip rules are re-applied;"),
            .listItem(level: 2, marker: .bullet, text: "a retry waits for a working day."),
            .listItem(level: 0, marker: .ordered("2."), text: "Second point"),
        ])
    }

    func testParagraphsKeepSingleLineBreaks() {
        XCTAssertEqual(MarkdownParser.parse("first line\nsecond line\n\nnew paragraph"), [
            .paragraph("first line\nsecond line"),
            .paragraph("new paragraph"),
        ])
    }

    func testIndentedContinuationBelongsToItem() {
        XCTAssertEqual(MarkdownParser.parse("- item\n  more of the item\nafter"), [
            .listItem(level: 0, marker: .bullet, text: "item\nmore of the item"),
            .paragraph("after"),
        ])
    }

    func testHeadingsCodeQuoteRuleAndTasks() {
        let text = """
        ## Plan
        > keep it simple
        ```swift
        let x = 1

        print(x)
        ```
        ---
        - [ ] write tests
        - [x] ship
        #hashtag
        """
        XCTAssertEqual(MarkdownParser.parse(text), [
            .heading(level: 2, text: "Plan"),
            .quote("keep it simple"),
            .code("let x = 1\n\nprint(x)"),
            .rule,
            .listItem(level: 0, marker: .task(done: false), text: "write tests"),
            .listItem(level: 0, marker: .task(done: true), text: "ship"),
            .paragraph("#hashtag"),
        ])
    }

    func testTable() {
        let text = "| Name | Age |\n|---|:--:|\n| Ann | 3 |\n| Bo | 4 |"
        XCTAssertEqual(MarkdownParser.parse(text), [
            .table(header: ["Name", "Age"], rows: [["Ann", "3"], ["Bo", "4"]]),
        ])
    }

    func testNotListsOrRules() {
        XCTAssertEqual(MarkdownParser.parse("-not a list\n2024 was fine\n-- dashes"), [
            .paragraph("-not a list\n2024 was fine\n-- dashes"),
        ])
    }

    func testTruncateRespectsBudget() {
        let blocks = (1...20).map { MarkdownBlock.listItem(level: 0, marker: .bullet, text: "item \($0)") }
        XCTAssertEqual(MarkdownText.truncate(blocks, budget: 8).count, 8)
    }
}
