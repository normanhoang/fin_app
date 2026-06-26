import SwiftUI

/// Single-select category picker styled like the Dashboard "Spending Categories"
/// filter popover. Tapping a row applies the selection and dismisses immediately.
/// Pass `selectedName`/`isUncategorizedSelected` so the active row is highlighted;
/// `onSelect(nil)` means the "Uncategorized" row was chosen.
struct CategoryPickerPopup: View {
    let categories: [Category]
    let selectedName: String?
    let isUncategorizedSelected: Bool
    let onSelect: (Category?) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Category")
            ScrollView {
                VStack(spacing: 4) {
                    row(name: "Uncategorized", icon: "questionmark.circle",
                        color: Color.textSecondary, selected: isUncategorizedSelected) {
                        onSelect(nil)
                    }
                    ForEach(categories) { category in
                        row(name: category.name, icon: category.systemIcon,
                            color: Color(hex: category.colorHex),
                            selected: category.name == selectedName) {
                            onSelect(category)
                        }
                    }
                }
            }
            .frame(maxHeight: 360)
        }
        .padding(16)
        .frame(width: 260)
        .background(Color.surface)
    }

    private func row(name: String, icon: String, color: Color, selected: Bool,
                     action: @escaping () -> Void) -> some View {
        Button {
            action()
            dismiss()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(color)
                    .frame(width: 22)
                Text(name)
                    .foregroundStyle(Color.textPrimary)
                Spacer(minLength: 16)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.brand)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(selected ? Color.brand.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(name)
    }
}
