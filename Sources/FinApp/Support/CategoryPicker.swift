import SwiftUI
import SwiftData

/// A full-height sheet that shows every category as a grid, so all options fit
/// without scrolling. Used to change a transaction/bill's category and to filter
/// the Transactions list.
struct CategoryPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Category.name) private var categories: [Category]
    /// When set, also offers an "Uncategorized" option (used for filtering).
    var includeUncategorized: Bool = false
    var current: Category?
    let onSelect: (Category?) -> Void

    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    if includeUncategorized {
                        cell("Uncategorized", "questionmark.circle", Color(hex: "#8E8E93"),
                             selected: current == nil) { onSelect(nil); dismiss() }
                    }
                    ForEach(categories) { category in
                        cell(category.name, category.systemIcon, Color(hex: category.colorHex),
                             selected: category == current) { onSelect(category); dismiss() }
                    }
                }
                .padding()
            }
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationDetents([.large])
    }

    private func cell(_ name: String, _ icon: String, _ color: Color,
                      selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    Circle().fill(color.opacity(0.16))
                    Image(systemName: icon).font(.system(size: 18)).foregroundStyle(color)
                }
                .frame(width: 46, height: 46)
                Text(name)
                    .font(.caption)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(selected ? Color.brand.opacity(0.14) : Color.surface,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? Color.brand : Color.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("pickCategory-\(name)")
    }
}
