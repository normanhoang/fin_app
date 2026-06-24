import SwiftUI
import SwiftData
import Charts

struct NetWorthDetailView: View {
    @Query(sort: \NetWorthSnapshot.day) private var snapshots: [NetWorthSnapshot]

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
                        Chart(snapshots) { point in
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
                        .chartXAxis { AxisMarks { _ in AxisValueLabel().foregroundStyle(Color.textSecondary) } }
                        .chartYAxis { AxisMarks { _ in
                            AxisGridLine().foregroundStyle(Color.hairline)
                            AxisValueLabel().foregroundStyle(Color.textSecondary)
                        } }
                        .frame(height: 240)
                        .padding(.vertical, 8)
                    }
                    .listRowBackground(Color.surface)
                }
                .screenBackground()
            }
        }
        .navigationTitle("Net Worth")
        .navigationBarTitleDisplayMode(.inline)
    }
}
