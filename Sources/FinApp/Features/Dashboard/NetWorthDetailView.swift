import SwiftUI
import SwiftData
import Charts

/// Selectable time window for the net-worth chart.
enum NWRange: String, CaseIterable, Identifiable {
    case oneMonth = "1M", threeMonths = "3M", sixMonths = "6M"
    case ytd = "YTD", oneYear = "1Y", fiveYears = "5Y", all = "All"
    var id: String { rawValue }

    /// Earliest day to include; nil means no lower bound (All).
    func start(now: Date = Date(), calendar: Calendar = .current) -> Date? {
        switch self {
        case .oneMonth: calendar.date(byAdding: .month, value: -1, to: now)
        case .threeMonths: calendar.date(byAdding: .month, value: -3, to: now)
        case .sixMonths: calendar.date(byAdding: .month, value: -6, to: now)
        case .ytd: calendar.date(from: calendar.dateComponents([.year], from: now))
        case .oneYear: calendar.date(byAdding: .year, value: -1, to: now)
        case .fiveYears: calendar.date(byAdding: .year, value: -5, to: now)
        case .all: nil
        }
    }
}

struct NetWorthDetailView: View {
    @Query(sort: \NetWorthSnapshot.day) private var snapshots: [NetWorthSnapshot]
    @State private var range: NWRange = .sixMonths

    private var filtered: [NetWorthSnapshot] {
        guard let start = range.start() else { return snapshots }
        return snapshots.filter { $0.day >= start }
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
                        rangePicker
                        chart
                    }
                    .listRowBackground(Color.surface)
                }
                .screenBackground()
            }
        }
        .navigationTitle("Net Worth")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var rangePicker: some View {
        ScrollView(.horizontal) {
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
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
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
                AreaMark(
                    x: .value("Day", point.day, unit: .day),
                    y: .value("Net Worth", (point.value as NSDecimalNumber).doubleValue)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(.linearGradient(
                    colors: [.brand.opacity(0.30), .brand.opacity(0.02)],
                    startPoint: .top, endPoint: .bottom
                ))
            }
            .chartXAxis {
                // Cap the number of labels and tilt them so dense data doesn't overlap.
                AxisMarks(values: .automatic(desiredCount: 5)) { value in
                    AxisGridLine().foregroundStyle(Color.hairline)
                    AxisValueLabel(anchor: .topTrailing) {
                        if let day = value.as(Date.self) {
                            Text(day, format: .dateTime.month(.abbreviated).day())
                                .font(.caption2)
                                .fixedSize()
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
            .frame(height: 240)
            .padding(.vertical, 8)
        }
    }
}
