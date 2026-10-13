import Foundation
import SwiftUI

enum ItemKind: String, Codable {
    /// Text captured from another app with ⇧⇧.
    case note
    /// Something you typed into the composer — usually a prompt to try next.
    case prompt
    case link
    case image
    case file
}

enum TagColor: String, Codable, CaseIterable, Identifiable {
    case red, orange, yellow, green, blue, purple

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        }
    }

    /// Number key that applies this tag (1–6).
    var shortcut: Int { (TagColor.allCases.firstIndex(of: self) ?? 0) + 1 }
}

struct Item: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var text: String
    var kind: ItemKind
    var done = false
    var tag: TagColor? = nil
    var sectionID: UUID
    var createdAt = Date()
    var doneAt: Date? = nil
    /// Name of the app the item was captured from.
    var source: String? = nil
    /// File name inside the images directory, for `.image` items.
    var imageFile: String? = nil
}

struct Section: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var name: String
    var collapsed = false
    var createdAt = Date()
}

struct Database: Codable, Equatable {
    var version = 1
    var sections: [Section]
    var items: [Item]
    var activeSectionID: UUID?

    static func fresh() -> Database {
        let inbox = Section(name: "Inbox")
        return Database(sections: [inbox], items: [], activeSectionID: inbox.id)
    }
}
