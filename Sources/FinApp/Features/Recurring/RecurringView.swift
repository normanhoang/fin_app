import SwiftUI
import SwiftData

struct RecurringView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppRouter.self) private var router
    @Query(sort: \RecurringBill.nextDue) private var bills: [RecurringBill]
    @Query(sort: \Transaction.posted, order: .reverse) private var allTransactions: [Transaction]
    @State private var path: [RecurringBill] = []
    /// Bumped on tab arrival to rebuild the List at the very top.
    @State private var topReset = 0
    @AppStorage("recurringShowCalendar") private var showCalendar = true
    @State private var displayedMonth = Calendar.current.dateInterval(of: .month, for: .now)?.start ?? .now
    @State private var selectedDay = Calendar.current.startOfDay(for: .now)

    // Sorted by the rolled-forward due date, not the stored one: a bill whose
    // stored nextDue slipped into the past (no new charge synced yet) would
    // otherwise pin to the top of the ascending @Query order.
    private var confirmed: [RecurringBill] {
        bills.filter { $0.confirmed && !$0.dismissed }
            .sorted { ($0.effectiveNextDue ?? .distantFuture) < ($1.effectiveNextDue ?? .distantFuture) }
    }
    private var candidates: [RecurringBill] {
        bills.filter { !$0.confirmed && !$0.dismissed }
            .sorted { ($0.effectiveNextDue ?? .distantFuture) < ($1.effectiveNextDue ?? .distantFuture) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if confirmed.isEmpty && candidates.isEmpty {
                    ContentUnavailableView(
                        "No Recurring Bills",
                        systemImage: "arrow.clockwise",
                        description: Text("Subscriptions and bills are detected automatically as you sync.")
                    )
                } else if showCalendar {
                    calendarList
                } else {
                    upcomingList
                }
            }
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("Recurring")
            .fixLargeTitleInset(trigger: topReset)
            .navigationDestination(for: RecurringBill.self) { RecurringDetailView(bill: $0) }
            .toolbar {
                if !(confirmed.isEmpty && candidates.isEmpty) {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showCalendar.toggle() } label: {
                            Image(systemName: showCalendar ? "list.bullet" : "calendar")
                        }
                        .accessibilityLabel(showCalendar ? "Show list" : "Show calendar")
                        .accessibilityIdentifier("recurringModeToggle")
                    }
                }
            }
        }
        .onChange(of: router.selectedTab) {
            if router.selectedTab == AppTab.recurring.rawValue {
                router.subpageOpen = !path.isEmpty
                topReset += 1
                displayedMonth = Calendar.current.dateInterval(of: .month, for: .now)?.start ?? .now
                selectedDay = Calendar.current.startOfDay(for: .now)
            } else { path = [] }
        }
        .onChange(of: path) {
            if router.selectedTab == AppTab.recurring.rawValue { router.subpageOpen = !path.isEmpty }
        }
    }

    /// The original mode: upcoming confirmed bills plus detected candidates.
    private var upcomingList: some View {
        List {
            if !confirmed.isEmpty {
                Section {
                    ForEach(confirmed) { billRow($0) }
                } header: {
                    Text("Upcoming")
                }
                .listRowBackground(Color.surface)
            }
            detectedSection
        }
        .listRowSeparatorTint(Color.hairline)
        .screenBackground()
        .id(topReset)
    }

    private var calendarList: some View {
        List {
            Section {
                CalendarMonthCard(
                    month: displayedMonth,
                    selectedDay: $selectedDay,
                    markedDays: markedDays,
                    pastMarkedDays: pastMarkedDays,
                    onStep: { stepMonth(by: $0) }
                )
            }
            .listRowBackground(Color.surface)
            Section {
                let due = billsOnSelectedDay
                if due.isEmpty {
                    Text("Nothing due this day.").foregroundStyle(Color.textSecondary)
                } else {
                    ForEach(due) { billRow($0) }
                }
            } header: {
                Text(selectedDay.formatted(.dateTime.weekday(.wide).month().day()))
            }
            .listRowBackground(Color.surface)
            detectedSection
        }
        .listRowSeparatorTint(Color.hairline)
        .screenBackground()
        .id(topReset)
    }

    @ViewBuilder private var detectedSection: some View {
        if !candidates.isEmpty {
            Section {
                ForEach(candidates) { billRow($0) }
            } header: {
                Text("Detected")
            } footer: {
                Text("Tap a detected bill to confirm it or remove a false match.")
            }
            .listRowBackground(Color.surface)
        }
    }

    private var monthInterval: DateInterval {
        Calendar.current.dateInterval(of: .month, for: displayedMonth)
            ?? DateInterval(start: displayedMonth, duration: 0)
    }

    /// Days of the displayed month (1-based) with at least one projected occurrence.
    /// Anchored on the rolled-forward due date so a missed/overdue stored date
    /// doesn't paint a phantom "upcoming" dot on a day already gone by.
    private var markedDays: Set<Int> {
        let cal = Calendar.current
        var days = Set<Int>()
        for bill in confirmed {
            guard let anchor = bill.effectiveNextDue else { continue }
            for date in RecurringSchedule.occurrences(anchor: anchor, cadence: bill.cadence,
                                                      in: monthInterval, calendar: cal) {
                days.insert(cal.component(.day, from: date))
            }
        }
        return days
    }

    /// Actual charges already posted for confirmed bills within the displayed
    /// month. Only month-filtered transactions get merchant-normalized, so the
    /// per-render cost stays small.
    private var monthPastCharges: [(date: Date, merchant: String)] {
        let todayStart = Calendar.current.startOfDay(for: .now)
        let merchants = Set(confirmed.map(\.merchantName))
        return allTransactions.compactMap { txn in
            guard txn.posted >= monthInterval.start, txn.posted < monthInterval.end,
                  txn.posted < todayStart else { return nil }
            let merchant = CategorizationEngine.normalizeMerchant(txn.payee ?? txn.detail)
            guard merchants.contains(merchant) else { return nil }
            return (txn.posted, merchant)
        }
    }

    /// Days of the displayed month (1-based) with an actual past charge.
    private var pastMarkedDays: Set<Int> {
        let cal = Calendar.current
        return Set(monthPastCharges.map { cal.component(.day, from: $0.date) })
    }

    private var billsOnSelectedDay: [RecurringBill] {
        let cal = Calendar.current
        let chargedMerchants = Set(monthPastCharges
            .filter { cal.isDate($0.date, inSameDayAs: selectedDay) }
            .map(\.merchant))
        return confirmed.filter { bill in
            if chargedMerchants.contains(bill.merchantName) { return true }
            guard let anchor = bill.effectiveNextDue else { return false }
            return RecurringSchedule.occurrences(anchor: anchor, cadence: bill.cadence,
                                                 in: monthInterval, calendar: cal)
                .contains { cal.isDate($0, inSameDayAs: selectedDay) }
        }
    }

    /// Move the displayed month and re-seed the selection: today when the new
    /// month contains it, otherwise the 1st.
    private func stepMonth(by value: Int) {
        let cal = Calendar.current
        guard let month = cal.date(byAdding: .month, value: value, to: displayedMonth) else { return }
        displayedMonth = month
        if cal.isDate(.now, equalTo: month, toGranularity: .month) {
            selectedDay = cal.startOfDay(for: .now)
        } else {
            selectedDay = month
        }
    }

    private func billRow(_ bill: RecurringBill) -> some View {
        NavigationLink(value: bill) {
            RecurringRow(bill: bill)
        }
        .accessibilityIdentifier("recurringRow-\(bill.merchantName)")
    }
}

/// One-month grid: chevrons to change month, a ring on today, a filled circle
/// on the selection, and a dot under days with recurring charges — full brand
/// for projected upcoming, dimmed for charges that already posted.
private struct CalendarMonthCard: View {
    let month: Date
    @Binding var selectedDay: Date
    let markedDays: Set<Int>
    let pastMarkedDays: Set<Int>
    let onStep: (Int) -> Void

    private let calendar = Calendar.current

    /// Weeks of the month as rows of 7; nil pads align day 1 to its weekday
    /// column and square off the last row.
    private var weeks: [[Date?]] {
        guard let interval = calendar.dateInterval(of: .month, for: month),
              let dayCount = calendar.range(of: .day, in: .month, for: month)?.count else { return [] }
        let firstWeekday = calendar.component(.weekday, from: interval.start)
        let pad = (firstWeekday - calendar.firstWeekday + 7) % 7
        var cells: [Date?] = Array(repeating: nil, count: pad) + (0..<dayCount).map {
            calendar.date(byAdding: .day, value: $0, to: interval.start)
        }
        while cells.count % 7 != 0 { cells.append(nil) }
        return stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<$0 + 7]) }
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let shift = calendar.firstWeekday - 1
        return Array(symbols[shift...] + symbols[..<shift])
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button { onStep(-1) } label: {
                    Image(systemName: "chevron.left").foregroundStyle(Color.brand)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Previous month")
                .accessibilityIdentifier("calPrevMonth")
                Spacer()
                Text(month.formatted(.dateTime.month(.wide).year()))
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                Spacer()
                Button { onStep(1) } label: {
                    Image(systemName: "chevron.right").foregroundStyle(Color.brand)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Next month")
                .accessibilityIdentifier("calNextMonth")
            }
            Grid(horizontalSpacing: 0, verticalSpacing: 6) {
                GridRow {
                    ForEach(weekdaySymbols.indices, id: \.self) { i in
                        Text(weekdaySymbols[i])
                            .font(.caption2)
                            .foregroundStyle(Color.textSecondary)
                            .frame(maxWidth: .infinity)
                    }
                }
                ForEach(weeks.indices, id: \.self) { w in
                    GridRow {
                        ForEach(weeks[w].indices, id: \.self) { i in
                            if let date = weeks[w][i] {
                                dayCell(date)
                            } else {
                                Color.clear.frame(height: 34)
                            }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func dayCell(_ date: Date) -> some View {
        let day = calendar.component(.day, from: date)
        let isSelected = calendar.isDate(date, inSameDayAs: selectedDay)
        let isToday = calendar.isDateInToday(date)
        return Button { selectedDay = date } label: {
            VStack(spacing: 2) {
                Text("\(day)")
                    .font(.system(.footnote, design: .rounded,
                                  weight: isSelected || isToday ? .bold : .regular))
                    .foregroundStyle(isSelected ? .white : Color.textPrimary)
                    .frame(width: 28, height: 28)
                    .background {
                        if isSelected {
                            Circle().fill(Color.brand.opacity(0.7))
                        }
                        if isToday {
                            Circle().strokeBorder(Color.brand, lineWidth: 1.5)
                        }
                    }
                Circle()
                    .fill(dotColor(day))
                    .frame(width: 4, height: 4)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(date.formatted(.dateTime.month().day()))
        .accessibilityIdentifier("calDay-\(day)")
    }

    /// Projected upcoming wins over past when a day has both.
    private func dotColor(_ day: Int) -> Color {
        if markedDays.contains(day) { return .brand }
        if pastMarkedDays.contains(day) { return .brand.opacity(0.35) }
        return .clear
    }
}

struct RecurringRow: View {
    let bill: RecurringBill

    private var dueText: String? {
        bill.effectiveNextDue.map { "next \($0.formatted(.dateTime.month().day()))" }
    }

    var body: some View {
        let color = Color(hex: bill.category?.colorHex ?? "#8E8E93")
        return HStack(spacing: 12) {
            ZStack {
                Circle().fill(color.opacity(0.15))
                Image(systemName: bill.category?.systemIcon ?? "questionmark.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(color)
            }
            .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 4) {
                Text(bill.merchantName.capitalized).foregroundStyle(Color.textPrimary)
                HStack(spacing: 6) {
                    Chip(bill.cadence.rawValue.capitalized, color: .brand)
                    if let dueText {
                        Text(dueText).font(.caption).foregroundStyle(Color.textSecondary)
                    }
                }
            }
            Spacer()
            MoneyText(value: bill.expectedAmount, size: 16, weight: .semibold, color: .textSecondary)
        }
        .padding(.vertical, 2)
    }
}

/// Past charges for one recurring bill, with the ability to recategorize it.
struct RecurringDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(AppRouter.self) private var router
    @Query(sort: \Category.name) private var categories: [Category]
    @Query(sort: \Transaction.posted, order: .reverse) private var allTransactions: [Transaction]
    @Bindable var bill: RecurringBill
    @State private var amountText = ""
    @State private var showCategoryPicker = false

    /// This merchant's past charges, computed once on appear — normalizing every
    /// transaction is too expensive to re-run on each body evaluation, and the
    /// set can't change while the detail is open.
    @State private var matched: [Transaction] = []

    private var monthGroups: [(month: Date, txns: [Transaction])] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: matched) {
            cal.dateInterval(of: .month, for: $0.posted)?.start ?? $0.posted
        }
        return grouped.map { (month: $0.key, txns: $0.value) }.sorted { $0.month > $1.month }
    }

    var body: some View {
        List {
            Section {
                categoryMenu
                Picker("Cadence", selection: $bill.cadence) {
                    ForEach(Cadence.allCases, id: \.self) { cadence in
                        Text(cadence.rawValue.capitalized).tag(cadence)
                    }
                }
                .tint(Color.textPrimary)
                LabeledContent("Typical amount") {
                    TextField("0.00", text: $amountText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("recurringAmountField")
                }
                // Editing marks the date user-set, so detection won't overwrite it
                // until a new charge posts on/after it (see RecurringDetector.refresh).
                DatePicker("Next payment",
                           selection: Binding(
                               get: { bill.nextDue ?? Date() },
                               set: {
                                   bill.nextDue = $0
                                   bill.nextDueSetByUser = true
                                   try? context.save()
                               }
                           ),
                           displayedComponents: .date)
                    .accessibilityIdentifier("recurringNextDuePicker")
                if !bill.confirmed {
                    Button {
                        bill.confirmed = true
                        try? context.save()
                    } label: {
                        Label("Confirm Recurring", systemImage: "checkmark.circle")
                    }
                    .accessibilityIdentifier("confirmRecurringButton")
                }
                Button(role: .destructive) {
                    bill.dismissed = true
                    try? context.save()
                    dismiss()
                } label: {
                    Label("Delete Recurring", systemImage: "trash")
                }
                .accessibilityIdentifier("deleteRecurringButton")
            }
            .listRowBackground(Color.surface)

            if matched.isEmpty {
                Section("Past charges") {
                    Text("No past charges found for this merchant.")
                        .foregroundStyle(Color.textSecondary)
                }
                .listRowBackground(Color.surface)
            } else {
                ForEach(monthGroups, id: \.month) { group in
                    Section {
                        ForEach(group.txns) { txn in
                            Button { router.openTransaction(id: txn.id) } label: {
                                // contentShape makes the transparent gaps (Spacer,
                                // padding) hit-testable — plain buttons only hit
                                // opaque pixels otherwise.
                                TransactionRow(transaction: txn)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("recurringTxnRow-\(txn.id)")
                        }
                    } header: {
                        Text(group.month.formatted(.dateTime.month(.wide).year()))
                    }
                    .listRowBackground(Color.surface)
                }
            }
        }
        .listRowSeparatorTint(Color.hairline)
        .screenBackground()
        .navigationTitle(bill.merchantName.capitalized)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            amountText = NSDecimalNumber(decimal: bill.expectedAmount).stringValue
            matched = allTransactions.filter {
                CategorizationEngine.normalizeMerchant($0.payee ?? $0.detail) == bill.merchantName
            }
        }
        .onChange(of: amountText) { applyAmount() }
        .onChange(of: bill.cadenceRaw) { try? context.save() }
    }

    /// Persist an edited typical amount (ignores unparseable input).
    private func applyAmount() {
        guard let value = Decimal(string: amountText, locale: .current) else { return }
        bill.expectedAmount = value
        try? context.save()
    }

    private var categoryMenu: some View {
        Button {
            showCategoryPicker = true
        } label: {
            HStack {
                Label {
                    Text(bill.category?.name ?? "Uncategorized").foregroundStyle(.primary)
                } icon: {
                    Image(systemName: bill.category?.systemIcon ?? "questionmark.circle")
                        .foregroundStyle(Color(hex: bill.category?.colorHex ?? "#8E8E93"))
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("recurringCategoryMenu")
        .popover(isPresented: $showCategoryPicker) {
            CategoryPickerPopup(
                categories: categories,
                selectedName: bill.category?.name,
                isUncategorizedSelected: bill.category == nil,
                onSelect: { selected in
                    if let category = selected {
                        setCategory(category)
                    } else {
                        bill.category = nil
                        try? context.save()
                    }
                }
            )
            .presentationCompactAdaptation(.popover)
        }
    }

    /// Set the bill's category and apply it to this merchant's transactions, learning
    /// a rule so future charges categorize automatically.
    private func setCategory(_ category: Category) {
        bill.category = category
        if let sample = matched.first {
            // Apply just the learned rule to this merchant's other charges —
            // no need to re-run every rule against the whole store.
            let rule = CategorizationEngine.learn(from: sample, category: category, in: context)
            CategorizationEngine.apply(rule, in: context)
        } else {
            try? context.save()
        }
    }
}
