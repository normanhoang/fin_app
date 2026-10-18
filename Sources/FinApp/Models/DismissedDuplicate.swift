import Foundation
import SwiftData

/// A pair of accounts the user marked "Not a duplicate", so `DuplicateDetector`
/// never flags it again. `key` is `DuplicateDetector.pairKey` of the two ids.
@Model
final class DismissedDuplicate {
    @Attribute(.unique) var key: String

    init(key: String) {
        self.key = key
    }
}

extension DismissedDuplicate {
    /// Idempotent: dismissing an already-dismissed pair is a no-op.
    @MainActor
    static func dismiss(_ a: String, _ b: String, in context: ModelContext) {
        let key = DuplicateDetector.pairKey(a, b)
        let existing = (try? context.fetch(FetchDescriptor<DismissedDuplicate>())) ?? []
        guard !existing.contains(where: { $0.key == key }) else { return }
        context.insert(DismissedDuplicate(key: key))
        try? context.save()
    }
}
