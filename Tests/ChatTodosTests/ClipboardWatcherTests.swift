import XCTest
@testable import ChatTodos

final class ClipboardWatcherTests: XCTestCase {
    private let now = Date()
    private let terminal: pid_t = 501

    private func change(count: Int = 7, secondsAgo: TimeInterval = 2, pid: pid_t? = 501) -> ClipboardWatcher.Change {
        ClipboardWatcher.Change(count: count, date: now.addingTimeInterval(-secondsAgo), appPID: pid)
    }

    func testRecentCopyFromFrontAppIsUsed() {
        XCTAssertTrue(ClipboardWatcher.isUsable(change(), currentCount: 7, frontPID: terminal, consumedCount: nil, now: now))
    }

    func testCopyFromAnotherAppIsIgnored() {
        XCTAssertFalse(ClipboardWatcher.isUsable(change(pid: 999), currentCount: 7, frontPID: terminal, consumedCount: nil, now: now))
    }

    func testStaleCopyIsIgnored() {
        XCTAssertFalse(ClipboardWatcher.isUsable(change(secondsAgo: 31), currentCount: 7, frontPID: terminal, consumedCount: nil, now: now))
    }

    func testOverwrittenClipboardIsIgnored() {
        XCTAssertFalse(ClipboardWatcher.isUsable(change(), currentCount: 8, frontPID: terminal, consumedCount: nil, now: now))
    }

    func testAlreadyCapturedCopyIsNotSavedTwice() {
        XCTAssertFalse(ClipboardWatcher.isUsable(change(), currentCount: 7, frontPID: terminal, consumedCount: 7, now: now))
    }

    func testNoChangeOrNoFrontApp() {
        XCTAssertFalse(ClipboardWatcher.isUsable(nil, currentCount: 7, frontPID: terminal, consumedCount: nil, now: now))
        XCTAssertFalse(ClipboardWatcher.isUsable(change(), currentCount: 7, frontPID: nil, consumedCount: nil, now: now))
    }
}
