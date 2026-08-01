import SwiftUI
import SwiftData

struct TriageActionGate {
    private(set) var isProcessing = false

    mutating func begin() -> Bool {
        guard !isProcessing else { return false }
        isProcessing = true
        return true
    }

    mutating func finish() {
        isProcessing = false
    }
}

/// Invalidates a fling animation's pending completion when Undo intervenes:
/// the completion captures `generation` at fling start and only advances if it
/// is still current when the animation ends.
struct TriageFlingSequence {
    private(set) var generation = 0

    mutating func invalidate() { generation += 1 }

    func isCurrent(_ captured: Int) -> Bool { captured == generation }
}

@MainActor
enum TriageUndoExpiry {
    static func wait(
        token: UUID,
        duration: Duration,
        currentToken: () -> UUID?,
        clear: () -> Void
    ) async {
        do {
            try await Task.sleep(for: duration)
        } catch {
            return
        }
        guard currentToken() == token else { return }
        clear()
    }
}

/// Full-screen "review your uncategorized transactions" swipe flow. One
/// transaction at a time as a card: swipe right (or tap accept) files it under
/// the top suggestion, swipe left (or Skip) leaves it, "Not mine" clears it from
/// the queue. Every accept routes through `CategorizationEngine.assign` so the
/// learn() rule fires and future matching charges file automatically.
struct TriageView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    // The live set of things needing review, snapshotted into `queue` on appear so
    // assigning a category (which drops a row from this query) doesn't reshuffle
    // the deck mid-session. `categorizedByUser` excludes "Not mine" rows.
    @Query(filter: #Predicate<Transaction> { $0.category == nil && !$0.categorizedByUser },
           sort: \Transaction.posted, order: .reverse)
    private var uncategorized: [Transaction]
    @Query(sort: \Category.name) private var categories: [Category]
    @Query private var rules: [CategoryRule]
    @Query private var allTransactions: [Transaction]

    @State private var queue: [Transaction] = []
    @State private var index = 0
    @State private var drag: CGSize = .zero
    @State private var showPicker = false
    @State private var pastThreshold = false
    @State private var undo: UndoState?
    @State private var actionGate = TriageActionGate()
    @State private var flingSequence = TriageFlingSequence()

    private struct UndoState: Equatable {
        let token: UUID
        let txnID: PersistentIdentifier
        let categoryName: String
        let atIndex: Int
    }

    private let threshold: CGFloat = 110

    private var current: Transaction? { index < queue.count ? queue[index] : nil }
    private var next: Transaction? { index + 1 < queue.count ? queue[index + 1] : nil }

    private func suggestions(for txn: Transaction) -> [(category: Category, confidence: Double)] {
        CategorizationEngine.suggestions(forMatchText: txn.matchText, rules: rules,
                                         transactions: allTransactions)
    }

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                progressBar
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                Spacer(minLength: 12)
                cardStack
                    .padding(.horizontal, 20)
                Spacer()
                if current != nil {
                    bottomActions
                        .padding(.bottom, 24)
                }
            }
            if let undo { undoToast(undo) }
        }
        .onAppear { if queue.isEmpty { queue = uncategorized } }
        .task(id: undo) {
            guard let token = undo?.token else { return }
            await TriageUndoExpiry.wait(
                token: token,
                duration: .seconds(3),
                currentToken: { undo?.token },
                clear: { withAnimation { undo = nil } }
            )
        }
        .sheet(isPresented: $showPicker) {
            if let txn = current {
                CategoryPickerSheet(
                    categories: categories,
                    selectedName: nil,
                    isUncategorizedSelected: true,
                    merchant: CategorizationEngine.normalizeMerchant(txn.payee ?? txn.detail),
                    suggestions: suggestions(for: txn),
                    onSelect: { category in
                        if let category { accept(category, for: txn) }
                    }
                )
                .presentationDetents([.medium, .large])
            }
        }
        .sensoryFeedback(.selection, trigger: pastThreshold)
    }

    // MARK: Header + progress

    private var header: some View {
        ZStack {
            Text("Review")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
            HStack {
                Button("Done") { dismiss() }
                    .font(.system(size: 16))
                    .foregroundStyle(Color.textSecondary)
                    .accessibilityIdentifier("triageDone")
                Spacer()
                Text("\(min(index + 1, queue.count)) of \(queue.count)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.brand)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Color.brand.opacity(0.12), in: Capsule())
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    private var progressBar: some View {
        HStack(spacing: 4) {
            ForEach(0..<max(queue.count, 1), id: \.self) { i in
                Capsule()
                    .fill(i < index ? Color.brand : Color.hairline)
                    .frame(height: 3)
            }
        }
    }

    // MARK: Card stack

    @ViewBuilder
    private var cardStack: some View {
        if let txn = current {
            ZStack {
                if let next {
                    // The next card peeks behind, dimmed, so the queue keeps momentum.
                    card(next, isTop: false)
                        .scaleEffect(0.94)
                        .offset(y: 18)
                        .opacity(0.5)
                }
                card(txn, isTop: true)
                    .offset(x: drag.width, y: drag.height * 0.2)
                    .rotationEffect(.degrees(Double(drag.width / 22)))
                    .gesture(swipe(for: txn))
            }
        } else {
            emptyState
        }
    }

    private func card(_ txn: Transaction, isTop: Bool) -> some View {
        let accepting = isTop && drag.width > 40
        let skipping = isTop && drag.width < -40
        let topName = suggestions(for: txn).first?.category.name
        return VStack(spacing: 0) {
            hero(txn)
            if isTop {
                Divider().overlay(Color.hairline).padding(.horizontal, 20)
                suggestionList(txn)
                    .padding(20)
            }
        }
        .frame(maxWidth: .infinity)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.surface)
                LinearGradient(colors: [Color.brand.opacity(0.10), .clear],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
        )
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(accepting ? Color.brand : (skipping ? Color.negative : Color.hairline),
                          lineWidth: accepting || skipping ? 2 : 1))
        .overlay(alignment: .topLeading) {
            if accepting, let topName {
                stamp(topName, color: .brand)
            } else if skipping {
                stamp("SKIP", color: .negative)
            }
        }
    }

    private func hero(_ txn: Transaction) -> some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().fill(Color.textTertiary.opacity(0.15))
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.textSecondary)
            }
            .frame(width: 54, height: 54)
            Text(txn.payee ?? txn.detail)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
                .multilineTextAlignment(.center)
            MoneyText(value: txn.amount, code: txn.account?.currency ?? "USD",
                      size: 26, weight: .bold, color: amountColor(txn.amount))
            Text("\(txn.posted.formatted(.dateTime.month().day()))\(txn.account.map { " · \($0.displayName)" } ?? "")")
                .font(.system(size: 13))
                .foregroundStyle(Color.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 26)
        .padding(.bottom, 20)
    }

    private func suggestionList(_ txn: Transaction) -> some View {
        let picks = suggestions(for: txn)
        return VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Suggested")
            ForEach(Array(picks.enumerated()), id: \.element.category.name) { i, item in
                Button { accept(item.category, for: txn) } label: {
                    suggestionRow(item.category,
                                  confidence: i == 0 && item.confidence >= 0.9 ? item.confidence : nil,
                                  highlighted: i == 0)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("triageSuggestion-\(item.category.name)")
            }
            Button { showPicker = true } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(Color.textTertiary.opacity(0.15))
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.textSecondary)
                    }
                    .frame(width: 36, height: 36)
                    Text("All categories…")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.textTertiary)
                }
                .padding(12)
                .background(Color.surfaceElevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("triageAllCategories")
        }
    }

    private func suggestionRow(_ category: Category, confidence: Double?, highlighted: Bool) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color(hex: category.colorHex).opacity(0.18))
                Image(systemName: category.systemIcon)
                    .font(.system(size: 14))
                    .foregroundStyle(Color(hex: category.colorHex))
            }
            .frame(width: 36, height: 36)
            Text(category.name)
                .font(.system(size: 16, weight: highlighted ? .semibold : .regular))
                .foregroundStyle(Color.textPrimary)
            Spacer()
            if let confidence {
                Text("\(Int((confidence * 100).rounded()))% match")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.brand)
            }
        }
        .padding(12)
        .background(highlighted ? Color.brand.opacity(0.10) : Color.surfaceElevated,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(highlighted ? Color.brand.opacity(0.35) : .clear, lineWidth: 1))
    }

    private func stamp(_ text: String, color: Color) -> some View {
        Text(text.uppercased())
            .font(.system(size: 20, weight: .heavy))
            .tracking(1)
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(color, lineWidth: 3))
            .rotationEffect(.degrees(-12))
            .padding(20)
    }

    // MARK: Bottom actions

    private var bottomActions: some View {
        VStack(spacing: 10) {
            Text(helperText)
                .font(.system(size: 13))
                .foregroundStyle(Color.textSecondary)
                .frame(height: 16)
            HStack(spacing: 40) {
                circleButton(icon: "xmark", size: 52, fill: Color.surfaceElevated,
                             fg: Color.textPrimary, label: "Skip") { skip() }
                    .accessibilityIdentifier("triageSkip")
                circleButton(icon: "checkmark", size: 64, fill: Color.brand,
                             fg: Color.black, label: acceptLabel) { acceptTop() }
                    .accessibilityIdentifier("triageAccept")
                circleButton(icon: "arrow.down.to.line", size: 52, fill: Color.surfaceElevated,
                             fg: Color.textSecondary, label: "Not mine") { notMine() }
                    .accessibilityIdentifier("triageNotMine")
            }
        }
    }

    private var acceptLabel: String {
        current.flatMap { suggestions(for: $0).first?.category.name } ?? "File"
    }

    private var helperText: String {
        if drag.width > 40 { return "Release to file as \(acceptLabel)" }
        if drag.width < -40 { return "Release to skip" }
        return "Swipe left to skip · swipe right to accept"
    }

    private func circleButton(icon: String, size: CGFloat, fill: Color, fg: Color,
                              label: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 6) {
            Button(action: action) {
                ZStack {
                    Circle().fill(fill)
                        .shadow(color: fill == Color.brand ? .brand.opacity(0.4) : .clear,
                                radius: 14, y: 4)
                    Image(systemName: icon)
                        .font(.system(size: size * 0.36, weight: .semibold))
                        .foregroundStyle(fg)
                }
                .frame(width: size, height: size)
            }
            .buttonStyle(.plain)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(Color.brand)
            Text("All caught up")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
            Text("Nothing left to review.")
                .font(.system(size: 14))
                .foregroundStyle(Color.textSecondary)
            Button("Done") { dismiss() }
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.brand)
                .padding(.top, 8)
        }
    }

    // MARK: Undo toast

    private func undoToast(_ state: UndoState) -> some View {
        VStack {
            Spacer()
            HStack(spacing: 12) {
                Text("Filed as \(state.categoryName)")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.textPrimary)
                Spacer()
                Button("Undo") { performUndo(state) }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.brand)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.surfaceElevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.hairline, lineWidth: 1))
            .padding(.horizontal, 20)
            .padding(.bottom, 110)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: Gestures + actions

    private func swipe(for txn: Transaction) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard !actionGate.isProcessing else { return }
                drag = value.translation
                pastThreshold = abs(value.translation.width) > threshold
            }
            .onEnded { value in
                if value.translation.width > threshold {
                    if let top = suggestions(for: txn).first?.category {
                        flingAccept(top, for: txn)
                    } else {
                        withAnimation(.spring) { drag = .zero }
                    }
                } else if value.translation.width < -threshold {
                    flingSkip()
                } else {
                    withAnimation(.spring) { drag = .zero }
                }
                pastThreshold = false
            }
    }

    private func acceptTop() {
        guard let txn = current, let top = suggestions(for: txn).first?.category else { return }
        flingAccept(top, for: txn)
    }

    private func flingAccept(_ category: Category, for txn: Transaction) {
        guard actionGate.begin() else { return }
        CategorizationEngine.assign(category, to: txn, in: context)
        let generation = flingSequence.generation
        withAnimation { undo = UndoState(token: UUID(), txnID: txn.persistentModelID,
                                         categoryName: category.name, atIndex: index) }
        withAnimation(.easeIn(duration: 0.22)) {
            drag = CGSize(width: 600, height: 0)
        } completion: { advance(ifCurrent: generation) }
    }

    private func flingSkip() {
        guard actionGate.begin() else { return }
        let generation = flingSequence.generation
        withAnimation { undo = nil }
        withAnimation(.easeIn(duration: 0.22)) {
            drag = CGSize(width: -600, height: 0)
        } completion: { advance(ifCurrent: generation) }
    }

    /// Files `txn` under `category`, records the undo target, and advances.
    private func accept(_ category: Category, for txn: Transaction) {
        flingAccept(category, for: txn)
    }

    private func skip() {
        flingSkip()
    }

    private func notMine() {
        guard let txn = current, actionGate.begin() else { return }
        CategorizationEngine.assign(nil, to: txn, in: context)
        let generation = flingSequence.generation
        withAnimation { undo = nil }
        withAnimation(.easeIn(duration: 0.22)) {
            drag = CGSize(width: -600, height: 0)
        } completion: { advance(ifCurrent: generation) }
    }

    /// Completion of a fling animation. Always releases the gate; only advances
    /// if no undo invalidated this fling while it was animating.
    private func advance(ifCurrent generation: Int) {
        drag = .zero
        actionGate.finish()
        guard flingSequence.isCurrent(generation) else { return }
        index += 1
    }

    private func performUndo(_ state: UndoState) {
        guard let txn = queue.first(where: { $0.persistentModelID == state.txnID }) else { return }
        // An in-flight fling's completion must not advance past the restored card.
        flingSequence.invalidate()
        // Revert the transaction to uncategorized and step back to it. The learned
        // rule stays (a minor over-teach), but the charge itself is un-filed.
        txn.category = nil
        txn.categorizedByUser = false
        try? context.save()
        withAnimation {
            index = state.atIndex
            drag = .zero
            undo = nil
        }
    }
}
