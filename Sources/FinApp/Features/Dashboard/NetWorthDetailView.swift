import SwiftUI
import SwiftData
import Charts

/// Selectable time window for the net-worth chart.
enum NWRange: String, CaseIterable, Identifiable {
    case oneMonth = "1M", threeMonths = "3M", sixMonths = "6M"
    case ytd = "YTD", oneYear = "1Y", all = "All"
    var id: String { rawValue }

    /// Earliest day to include; nil means no lower bound (All).
    func start(now: Date = Date(), calendar: Calendar = .current) -> Date? {
        switch self {
        case .oneMonth: calendar.date(byAdding: .month, value: -1, to: now)
        case .threeMonths: calendar.date(byAdding: .month, value: -3, to: now)
        case .sixMonths: calendar.date(byAdding: .month, value: -6, to: now)
        case .ytd: calendar.date(from: calendar.dateComponents([.year], from: now))
        case .oneYear: calendar.date(byAdding: .year, value: -1, to: now)
        case .all: nil
        }
    }
}

struct NetWorthDetailView: View {
    @Environment(AppRouter.self) private var router
    @Query(sort: \NetWorthSnapshot.day) private var snapshots: [NetWorthSnapshot]
    @State private var range: NWRange = .sixMonths
    @State private var selectedDate: Date?
    /// True while a finger is down on the chart, so page swiping is blocked from
    /// touch-down — not just once a scrub selection engages.
    @State private var chartTouch = false

    private var filtered: [NetWorthSnapshot] {
        guard let start = range.start() else { return snapshots }
        return snapshots.filter { $0.day >= start }
    }

    /// Y range hugging the data (not zero-based) so small changes read as slope.
    /// Top headroom keeps the scrub popup clear of a near-max dot.
    private var yDomain: ClosedRange<Double> {
        let vals = filtered.map { ($0.value as NSDecimalNumber).doubleValue }
        let maxV = vals.max() ?? 1
        let minV = vals.min() ?? 0
        // Flat history (or a single value) still needs a non-zero span.
        let span = Swift.max(maxV - minV, Swift.max(abs(maxV) * 0.01, 1))
        return (minV - span * 0.08) ... (maxV + span * 0.25)
    }

    /// Fractional change across the selected range; nil when <2 points or zero baseline.
    private var rangeDelta: Double? {
        guard let first = filtered.first, let last = filtered.last, first.day < last.day else { return nil }
        let from = (first.value as NSDecimalNumber).doubleValue
        guard from != 0 else { return nil }
        let to = (last.value as NSDecimalNumber).doubleValue
        return (to - from) / abs(from)
    }

    /// Snapshot in `filtered` whose day is closest to the scrubbed x-position.
    private var selectedSnapshot: NetWorthSnapshot? {
        guard let selectedDate else { return nil }
        return filtered.min {
            abs($0.day.timeIntervalSince(selectedDate)) < abs($1.day.timeIntervalSince(selectedDate))
        }
    }

    var body: some View {
        Group {
            if snapshots.count < 2 {
                ContentUnavailableView(
                    "Building History",
                    systemImage: "chart.line.uptrend.xyaxis",
                    description: Text("Your net worth graph fills in as you sync over the coming days.")
                )
            } else {
                List {
                    Section {
                        // One row for picker + chip + chart so List draws no
                        // separator between them. Even spacing keeps the chip
                        // visually centered between the buttons and the graph.
                        VStack(spacing: 12) {
                            rangePicker
                            if let rangeDelta {
                                HStack { Spacer(); deltaChip(rangeDelta) }
                            }
                            chart
                        }
                    }
                    .listRowBackground(Color.surface)
                }
                .screenBackground()
            }
        }
        .navigationTitle("Net Worth")
        .navigationBarTitleDisplayMode(.inline)
        // While a finger is on the chart or a scrub selection is active, the
        // horizontal drag is the chart's — block the left-swipe-to-next-tab
        // gesture so scrubbing can't page away.
        .onChange(of: selectedDate) { updateSuppress() }
        .onDisappear { router.suppressPageSwipe = false }
    }

    private func updateSuppress() {
        router.suppressPageSwipe = chartTouch || selectedDate != nil
    }

    private var rangePicker: some View {
        HStack(spacing: 8) {
            ForEach(NWRange.allCases) { option in
                Button {
                    range = option
                } label: {
                    Text(option.rawValue)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(range == option ? Color.brand : Color.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background((range == option ? Color.brand.opacity(0.16) : Color.surfaceElevated),
                                    in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
    }

    private func deltaChip(_ value: Double) -> some View {
        let up = value >= 0
        return HStack(spacing: 3) {
            Image(systemName: up ? "arrow.up.right" : "arrow.down.right")
            Text(value.formatted(.percent.precision(.fractionLength(1))))
        }
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .foregroundStyle(up ? Color.positive : Color.negative)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background((up ? Color.positive : Color.negative).opacity(0.12), in: Capsule())
    }

    @ViewBuilder
    private var chart: some View {
        if filtered.count < 2 {
            Text("Not enough history for this range yet.")
                .font(.subheadline)
                .foregroundStyle(Color.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 200)
        } else {
            Chart(filtered) { point in
                LineMark(
                    x: .value("Day", point.day, unit: .day),
                    y: .value("Net Worth", (point.value as NSDecimalNumber).doubleValue)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(Color.brand)
                .lineStyle(StrokeStyle(lineWidth: 2.5))
                // Fill starts at the domain floor, not 0 — with a data-hugging
                // domain a 0 baseline would paint below the plot (no clipping).
                AreaMark(
                    x: .value("Day", point.day, unit: .day),
                    yStart: .value("Base", yDomain.lowerBound),
                    yEnd: .value("Net Worth", (point.value as NSDecimalNumber).doubleValue)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(.linearGradient(
                    colors: [.brand.opacity(0.30), .brand.opacity(0.02)],
                    startPoint: .top, endPoint: .bottom
                ))

                if let selectedSnapshot {
                    RuleMark(x: .value("Day", selectedSnapshot.day, unit: .day))
                        .foregroundStyle(Color.textSecondary.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    // The label rides the PointMark (the last-drawn mark) so it renders
                    // on top of every other element; `y: .disabled` keeps it directly
                    // above the dot instead of being pushed down onto it.
                    PointMark(
                        x: .value("Day", selectedSnapshot.day, unit: .day),
                        y: .value("Net Worth", (selectedSnapshot.value as NSDecimalNumber).doubleValue)
                    )
                    .foregroundStyle(Color.brand)
                    .symbolSize(80)
                    .annotation(position: .top, spacing: 8,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        scrubLabel(selectedSnapshot)
                    }
                }
            }
            .chartXSelection(value: $selectedDate)
            .chartYScale(domain: yDomain)
            .chartXAxis {
                // Cap the number of labels and tilt them so dense data doesn't overlap.
                AxisMarks(values: .automatic(desiredCount: 5)) { value in
                    AxisGridLine().foregroundStyle(Color.hairline)
                    AxisValueLabel(anchor: .topTrailing) {
                        if let day = value.as(Date.self) {
                            Text(day, format: .dateTime.month(.abbreviated).day())
                                .font(.caption2)
                                .fixedSize()
                                // rotationEffect doesn't change the layout box, so
                                // the tilted text pokes ~13pt above and below it and
                                // gets clipped/crosses the axis. Vertical padding
                                // grows the box so the chart reserves enough room.
                                .padding(.vertical, 10)
                                .rotationEffect(.degrees(-35))
                                .foregroundStyle(Color.textSecondary)
                        }
                    }
                }
            }
            .chartYAxis { AxisMarks { _ in
                AxisGridLine().foregroundStyle(Color.hairline)
                AxisValueLabel().foregroundStyle(Color.textSecondary)
            } }
            .frame(height: 260)
            .padding(.bottom, 8)
            // Block page swiping from the moment a touch moves on the chart —
            // waiting for chartXSelection to engage lets the pager grab the
            // first ~10pt and slide the page. simultaneousGesture keeps the
            // scrub and vertical List scroll working.
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        chartTouch = true
                        updateSuppress()
                    }
                    .onEnded { _ in
                        chartTouch = false
                        updateSuppress()
                    }
            )
            .accessibilityIdentifier("netWorthChart")
        }
    }

    private func scrubLabel(_ snapshot: NetWorthSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(snapshot.day, format: .dateTime.month(.abbreviated).day().year())
                .font(.caption2)
                .foregroundStyle(Color.textSecondary)
            Text(Money.string(snapshot.value))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.surfaceElevated, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.hairline))
    }
}
