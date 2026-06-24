import Foundation
import SwiftData

/// A keyword rule: if a transaction's match text contains `keyword`, it gets
/// this rule's category. Lower `priority` value wins (applied first).
@Model
final class CategoryRule {
    @Attribute(.unique) var id: UUID
    var keyword: String         // stored lowercased
    var priority: Int
    var createdByUser: Bool
    var category: Category?

    init(
        id: UUID = UUID(),
        keyword: String,
        priority: Int = 100,
        createdByUser: Bool = false,
        category: Category? = nil
    ) {
        self.id = id
        self.keyword = keyword.lowercased()
        self.priority = priority
        self.createdByUser = createdByUser
        self.category = category
    }

    func matches(_ text: String) -> Bool {
        text.contains(keyword)
    }
}
