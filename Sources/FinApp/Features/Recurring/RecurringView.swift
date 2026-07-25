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
                        modeControl
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

    /// Labeled List | Calendar segments, bound to the persisted mode flag.
    /// No own capsule/track: the iOS 26 toolbar wraps this in a glass capsule that
    /// is the sole container — a second capsule here read as a doubled border.
    /// Only the active segment draws its green pill. No container identifier
    /// either: it would propagate onto the child buttons and clobber their
    /// recurringSeg-* identifiers in the AX tree.
    private var modeControl: some View {
        HStack(spacing: 2) {
            modeSegment("List", selected: !showCalendar) { showCalendar = false }
            modeSegment("Calendar", selected: showCalendar) { showCalendar = true }
        }
    }

    private func modeSegment(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(selected ? Color.appBackground : Color.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(selected ? Color.brand : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show \(label.lowercased())")
        .accessibilityIdentifier("recurringSeg-\(label)")
    }

    /// List mode: monthly summary, price alerts, due-soon bills, candidates.
    private var upcomingList: some View {
        List {
            summarySection
            priceAlertSection
            if !confirmed.isEmpty {
                Section {
                    ForEach(confirmed) { billRow($0) }
                } header: {
                    Text("Due Soon")
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
            summarySection
            priceAlertSection
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

    // MARK: This-month summary

    private var summarySection: some View {
        Section {
            summaryCard
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
    }

    private var summaryCard: some View {
        let monthlyTotal = confirmed.reduce(Decimal(0)) { $0 + $1.monthlyEquivalent }
        return VStack(alignment: .leading, spacing: 10) {
            SectionLabel("This month")
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                MoneyText(value: monthlyTotal, size: 30, weight: .bold)
                Text("/mo · \(confirmed.count) \(confirmed.count == 1 ? "bill" : "bills")")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.textSecondary)
            }
            if let next = nextCharge {
                (Text("Next charge ").foregroundStyle(Color.textSecondary)
                    + Text(next.date.formatted(.dateTime.month(.abbreviated).day()))
                        .fontWeight(.medium).foregroundStyle(Color.textPrimary)
                    + Text(" — ").foregroundStyle(Color.textSecondary)
                    + Text(next.names).fontWeight(.medium).foregroundStyle(Color.textPrimary)
                    + Text(", \(Money.string(next.total))").foregroundStyle(Color.textSecondary))
                    .font(.system(size: 12.5))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.surface)
                .overlay(
                    LinearGradient(colors: [.brand.opacity(0.10), .clear],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.hairline, lineWidth: 1)
        )
        .accessibilityIdentifier("recurringSummaryCard")
    }

    /// Earliest upcoming charge; bills due the same day are combined.
    private var nextCharge: (date: Date, names: String, total: Decimal)? {
        let dated = confirmed.compactMap { bill in bill.effectiveNextDue.map { (bill, $0) } }
        guard let earliest = dated.min(by: { $0.1 < $1.1 }) else { return nil }
        let cal = Calendar.current
        let sameDay = dated.filter { cal.isDate($0.1, inSameDayAs: earliest.1) }
        let names = sameDay.map { $0.0.merchantName.capitalized }.joined(separator: " + ")
        let total = sameDay.reduce(Decimal(0)) { $0 + $1.0.expectedAmount }
        return (earliest.1, names, total)
    }

    // MARK: Price-change alerts

    @ViewBuilder private var priceAlertSection: some View {
        let flagged = confirmed.filter(\.priceWentUp)
        if !flagged.isEmpty {
            Section {
                ForEach(flagged) { bill in
                    priceAlertCard(bill)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
        }
    }

    private func priceAlertCard(_ bill: RecurringBill) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.negative)
            // Tap the body to open the bill's detail.
            Button { path.append(bill) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(bill.merchantName.capitalized) price went up")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)
                    priceChangeLine(bill)
                        .font(.system(size: 12))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { acknowledgePrice(bill) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.textSecondary)
                    .padding(6)
                    .background(Color.negative.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss price alert")
            .accessibilityIdentifier("dismissPriceAlert-\(bill.merchantName)")
        }
        .padding(14)
        .background(Color.negative.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.negative.opacity(0.35), lineWidth: 1))
        .padding(.horizontal, 16)
        .accessibilityIdentifier("priceChangeAlert-\(bill.merchantName)")
    }

    /// Hide the price-increase alert for this bill's current amount. A further
    /// increase changes `expectedAmount`, so `priceWentUp` fires again.
    private func acknowledgePrice(_ bill: RecurringBill) {
        bill.priceAckAmount = bill.expectedAmount
        try? context.save()
    }

    /// "$13.99 → $15.49 since June · +$18/yr"
    private func priceChangeLine(_ bill: RecurringBill) -> Text {
        let old = Money.string(bill.previousAmount ?? 0)
        let new = Money.string(bill.expectedAmount)
        let since = bill.amountChangedAt.map { " since \($0.formatted(.dateTime.month(.wide)))" } ?? ""
        let yearly = (bill.expectedAmount - (bill.previousAmount ?? 0)) * bill.chargesPerYear
        let perYear = yearly.formatted(.currency(code: "USD").precision(.fractionLength(0)))
        return Text("\(old) → ").foregroundStyle(Color.textSecondary)
            + Text(new).fontWeight(.semibold).foregroundStyle(Color.negative)
            + Text("\(since) · +\(perYear)/yr").foregroundStyle(Color.textSecondary)
    }

    // MARK: Detected candidates

    @ViewBuilder private var detectedSection: some View {
        if !candidates.isEmpty {
            Section {
                ForEach(candidates) { candidateRow($0) }
            } header: {
                Text("Detected — Needs Review")
            }
            .listRowBackground(Color.surface)
        }
    }

    /// Candidate with inline triage: Confirm / Not a bill. The row itself still
    /// links to the detail page; dismiss sets `dismissed` — never deletes — so
    /// re-detection can't resurface it.
    private func candidateRow(_ bill: RecurringBill) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            NavigationLink(value: bill) {
                HStack(spacing: 12) {
                    let color = Color(hex: bill.category?.colorHex ?? "#8E8E93")
                    ZStack {
                        Circle().fill(color.opacity(0.15))
                        Image(systemName: bill.category?.systemIcon ?? "questionmark.circle")
                            .font(.system(size: 14))
                            .foregroundStyle(color)
                    }
                    .frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(bill.merchantName.capitalized)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Color.textPrimary)
                        Text(evidence(for: bill))
                            .font(.system(size: 12))
                            .foregroundStyle(Color.textSecondary)
                    }
                }
            }
            .accessibilityIdentifier("recurringRow-\(bill.merchantName)")
            HStack(spacing: 10) {
                Button {
                    bill.confirmed = true
                    try? context.save()
                } label: {
                    Text("Confirm")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Color.appBackground)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(Color.brand, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("confirmRecurringInline-\(bill.merchantName)")
                Button {
                    bill.dismissed = true
                    try? context.save()
                } label: {
                    Text("Not a bill")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(Color.surfaceElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.hairline, lineWidth: 1))
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("dismissRecurringInline-\(bill.merchantName)")
            }
        }
        .padding(.vertical, 4)
        // No container identifier — it would propagate down and clobber the
        // row/button identifiers inside (same AX quirk as the mode control).
    }

    /// "Looks monthly · 3 charges of $2.99" — the why behind a candidate.
    private func evidence(for bill: RecurringBill) -> String {
        let count = allTransactions.count {
            CategorizationEngine.normalizeMerchant($0.payee ?? $0.detail) == bill.merchantName
        }
        return "Looks \(bill.cadence.rawValue) · \(count) charges of \(Money.string(bill.expectedAmount))"
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

    /// "in 11 days" / "today" / "tomorrow" from the rolled-forward due date.
    private var relativeDue: String? {
        guard let due = bill.effectiveNextDue else { return nil }
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: .now),
                                      to: cal.startOfDay(for: due)).day ?? 0
        switch days {
        case ...0: return "today"
        case 1: return "tomorrow"
        default: return "in \(days) days"
        }
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
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(bill.merchantName.capitalized)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.textPrimary)
                    if bill.priceWentUp {
                        Text("PRICE UP")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.negative)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.negative.opacity(0.12), in: Capsule())
                    }
                }
                Text("\(bill.cadence.rawValue.capitalized)\(relativeDue.map { " · \($0)" } ?? "")")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.textSecondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                MoneyText(value: bill.expectedAmount, size: 15, weight: .semibold, color: .textPrimary)
                if let due = bill.effectiveNextDue {
                    Text(due.formatted(.dateTime.month(.abbreviated).day()))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.textSecondary)
                }
            }
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

    private var categoryColor: Color { Color(hex: bill.category?.colorHex ?? "#8E8E93") }

    /// Suffix for the hero amount, matching the bill's cadence.
    private var unitSuffix: String {
        switch bill.cadence {
        case .weekly: "/wk"
        case .biweekly: "/2wk"
        case .monthly: "/mo"
        case .quarterly: "/qtr"
        case .yearly: "/yr"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                hero
                if bill.priceWentUp { priceContextCard }
                SectionLabel("Details").padding(.horizontal, 4)
                detailsCard
                SectionLabel("Charge history").padding(.horizontal, 4)
                historyCard
                removeButton
                Text("Removing hides the bill — its transactions are kept.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.textTertiary)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .screenBackground()
        .navigationTitle("Bill")
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

    private var hero: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().fill(categoryColor.opacity(0.14))
                Image(systemName: bill.category?.systemIcon ?? "questionmark.circle")
                    .font(.system(size: 22))
                    .foregroundStyle(categoryColor)
            }
            .frame(width: 56, height: 56)
            HStack(spacing: 6) {
                Text(bill.merchantName.capitalized)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                if bill.priceWentUp {
                    Text("PRICE UP")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.negative)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.negative.opacity(0.12), in: Capsule())
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                MoneyText(value: bill.expectedAmount, size: 34, weight: .bold)
                Text(unitSuffix)
                    .font(.system(size: 16))
                    .foregroundStyle(Color.textSecondary)
            }
            Text(nextChargeLine)
                .font(.system(size: 13))
                .foregroundStyle(Color.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var nextChargeLine: String {
        var parts: [String] = []
        if let due = bill.effectiveNextDue {
            parts.append("Next charge \(due.formatted(.dateTime.month(.abbreviated).day()))")
        }
        if let account = matched.first?.account {
            parts.append(account.displayName)
        }
        return parts.joined(separator: " · ")
    }

    private var priceContextCard: some View {
        let old = Money.string(bill.previousAmount ?? 0)
        let new = Money.string(bill.expectedAmount)
        let yearly = (bill.expectedAmount - (bill.previousAmount ?? 0)) * bill.chargesPerYear
        let perYear = yearly.formatted(.currency(code: "USD").precision(.fractionLength(0)))
        let until = bill.amountChangedAt
            .flatMap { Calendar.current.date(byAdding: .month, value: -1, to: $0) }
            .map { " until \($0.formatted(.dateTime.month(.wide)))" } ?? ""
        return HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.negative)
            (Text("Was ").foregroundStyle(Color.textSecondary)
                + Text(old).fontWeight(.semibold).foregroundStyle(Color.textPrimary)
                + Text("\(until) · now ").foregroundStyle(Color.textSecondary)
                + Text(new).fontWeight(.semibold).foregroundStyle(Color.negative)
                + Text(" — costs ").foregroundStyle(Color.textSecondary)
                + Text("\(perYear) more per year").fontWeight(.semibold).foregroundStyle(Color.textPrimary))
                .font(.system(size: 13))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.negative.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.negative.opacity(0.25), lineWidth: 1))
    }

    private var detailsCard: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Cadence").font(.system(size: 14)).foregroundStyle(Color.textSecondary)
                Spacer()
                Menu {
                    Picker("Cadence", selection: $bill.cadence) {
                        ForEach(Cadence.allCases, id: \.self) { cadence in
                            Text(cadence.rawValue.capitalized).tag(cadence)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(bill.cadence.rawValue.capitalized)
                            .font(.system(size: 14, weight: .medium))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(Color.textPrimary)
                }
                .accessibilityIdentifier("recurringCadenceMenu")
            }
            .padding(.vertical, 13)
            Divider().overlay(Color.hairline)
            categoryMenu
            Divider().overlay(Color.hairline)
            HStack {
                Text("Typical amount").font(.system(size: 14)).foregroundStyle(Color.textSecondary)
                Spacer()
                TextField("0.00", text: $amountText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.textPrimary)
                    .frame(maxWidth: 120)
                    .accessibilityIdentifier("recurringAmountField")
            }
            .padding(.vertical, 13)
            Divider().overlay(Color.hairline)
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
                .font(.system(size: 14))
                .foregroundStyle(Color.textSecondary)
                .padding(.vertical, 7)
                .accessibilityIdentifier("recurringNextDuePicker")
            Divider().overlay(Color.hairline)
            HStack {
                Text("Yearly cost").font(.system(size: 14)).foregroundStyle(Color.textSecondary)
                Spacer()
                MoneyText(value: bill.expectedAmount * bill.chargesPerYear,
                          size: 14, weight: .medium)
            }
            .padding(.vertical, 13)
            if !bill.confirmed {
                Divider().overlay(Color.hairline)
                Button {
                    bill.confirmed = true
                    try? context.save()
                } label: {
                    Label("Confirm Recurring", systemImage: "checkmark.circle")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.brand)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 13)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("confirmRecurringButton")
            }
        }
        .padding(.horizontal, 16)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(Color.hairline, lineWidth: 1))
    }

    private var historyCard: some View {
        VStack(spacing: 0) {
            if matched.isEmpty {
                Text("No past charges found for this merchant.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 13)
            } else {
                ForEach(Array(matched.prefix(12).enumerated()), id: \.element.id) { index, txn in
                    if index > 0 { Divider().overlay(Color.hairline) }
                    Button { router.openTransaction(id: txn.id) } label: {
                        HStack {
                            Text(txn.posted.formatted(date: .abbreviated, time: .omitted))
                                .font(.system(size: 14))
                                .foregroundStyle(Color.textPrimary)
                            Spacer()
                            // The changed amount stays tinted so the jump is scannable.
                            MoneyText(value: abs(txn.amount), size: 14, weight: .semibold,
                                      color: bill.priceWentUp && abs(txn.amount) == bill.expectedAmount
                                          ? .negative : .textPrimary)
                        }
                        .padding(.vertical, 13)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("recurringTxnRow-\(txn.id)")
                }
            }
        }
        .padding(.horizontal, 16)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(Color.hairline, lineWidth: 1))
    }

    private var removeButton: some View {
        Button {
            // Dismissed, never deleted — re-detection can't resurface it and
            // the merchant's transactions are untouched.
            bill.dismissed = true
            try? context.save()
            dismiss()
        } label: {
            Text("Remove from Recurring")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.negative)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(Color.negative.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.negative.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("deleteRecurringButton")
        .padding(.top, 4)
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
                Text("Category")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.textSecondary)
                Spacer()
                Text(bill.category?.name ?? "Uncategorized")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(bill.category.map { Color(hex: $0.colorHex) } ?? Color.textSecondary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.textSecondary)
            }
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("recurringCategoryMenu")
        .sheet(isPresented: $showCategoryPicker) {
            CategoryPickerSheet(
                categories: categories,
                selectedName: bill.category?.name,
                isUncategorizedSelected: bill.category == nil,
                merchant: bill.merchantName,
                onSelect: { selected in
                    if let category = selected {
                        setCategory(category)
                    } else {
                        bill.category = nil
                        try? context.save()
                    }
                }
            )
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
