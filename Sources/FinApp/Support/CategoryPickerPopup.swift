import SwiftUI

/// Single-select category picker presented as a medium-detent sheet: search,
/// learn()-ranked suggestion chips, then all categories as a 3-up grid.
/// Tapping a tile applies the selection and dismisses. `onSelect(nil)` means
/// the dashed "Uncategorized" tile was chosen. Selection is routed through
/// `CategorizationEngine.assign` by the callers.
struct CategoryPickerSheet: View {
    let categories: [Category]
    let selectedName: String?
    let isUncategorizedSelected: Bool
    var merchant: String? = nil
    var suggestions: [(category: Category, confidence: Double)] = []
    let onSelect: (Category?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var filtered: [Category] {
        search.isEmpty ? categories
            : categories.filter { $0.name.range(of: search, options: .caseInsensitive) != nil }
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Text("Category")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.brand)
                        .accessibilityIdentifier("categoryPickerDone")
                }
            }
            searchField
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !suggestions.isEmpty && search.isEmpty {
                        SectionLabel(merchant.map { "Suggested for \"\($0)\"" } ?? "Suggested")
                        HStack(spacing: 8) {
                            ForEach(Array(suggestions.enumerated()), id: \.element.category.name) { index, item in
                                suggestionChip(item.category,
                                               confidence: index == 0 && item.confidence >= 0.9
                                                   ? item.confidence : nil,
                                               highlighted: index == 0)
                            }
                        }
                        .padding(.bottom, 4)
                    }
                    SectionLabel("All categories")
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(filtered) { category in
                            tile(name: category.name, icon: category.systemIcon,
                                 color: Color(hex: category.colorHex),
                                 selected: category.name == selectedName) {
                                onSelect(category)
                            }
                        }
                        if search.isEmpty {
                            uncategorizedTile
                        }
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 11))
                        Text("Picking here teaches FinApp — future \(merchant.map { $0.capitalized } ?? "matching") charges file automatically.")
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(Color.textTertiary)
                    .padding(.top, 4)
                }
                .padding(.bottom, 16)
            }
        }
        .padding(16)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.surface)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Color.textTertiary)
            TextField("", text: $search,
                      prompt: Text("Search categories").foregroundStyle(Color.textTertiary))
                .textFieldStyle(.plain)
                .foregroundStyle(Color.textPrimary)
                .autocorrectionDisabled()
                .accessibilityIdentifier("categorySearchField")
        }
        .padding(10)
        .background(Color.surfaceElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.hairline, lineWidth: 1))
    }

    private func suggestionChip(_ category: Category, confidence: Double?, highlighted: Bool) -> some View {
        Button {
            onSelect(category)
            dismiss()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: category.systemIcon)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: category.colorHex))
                Text(category.name)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                if let confidence {
                    Text("\(Int((confidence * 100).rounded()))%")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.brand)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(highlighted ? Color.brand.opacity(0.10) : Color.surfaceElevated, in: Capsule())
            .overlay(Capsule().strokeBorder(
                highlighted ? Color.brand.opacity(0.35) : Color.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("suggested-\(category.name)")
    }

    private func tile(name: String, icon: String, color: Color, selected: Bool,
                      action: @escaping () -> Void) -> some View {
        Button {
            action()
            dismiss()
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    Circle().fill(color.opacity(0.14))
                    Image(systemName: icon)
                        .font(.system(size: 13))
                        .foregroundStyle(color)
                }
                .frame(width: 30, height: 30)
                Text(name)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(selected ? Color.brand.opacity(0.10) : Color.surfaceElevated,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? Color.brand.opacity(0.5) : Color.hairline, lineWidth: 1))
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.brand)
                        .background(Circle().fill(Color.surface))
                        .padding(6)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(name)
    }

    private var uncategorizedTile: some View {
        Button {
            onSelect(nil)
            dismiss()
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    Circle().fill(Color.textSecondary.opacity(0.12))
                    Image(systemName: isUncategorizedSelected ? "checkmark" : "plus")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.textSecondary)
                }
                .frame(width: 30, height: 30)
                Text("Uncategorized")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(isUncategorizedSelected ? Color.brand.opacity(0.06) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.hairline, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("Uncategorized")
    }
}
