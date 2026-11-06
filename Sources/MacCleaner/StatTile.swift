import Charts
import SwiftUI

struct StatTile: View {
  let title: String
  let value: String
  let fraction: Double?
  let chart: Chart?

  /// A line under the value; the full view passes one, the menu bar window does not.
  struct Chart {
    let points: [(date: Date, value: Double)]
    let color: Color
    let caption: String
  }

  init(title: String, value: String, fraction: Double?, chart: Chart? = nil) {
    self.title = title
    self.value = value
    self.fraction = fraction
    self.chart = chart
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.caption2).foregroundStyle(.secondary)
      Text(value).font(.callout.weight(.semibold))
      if let fraction {
        ProgressView(value: fraction).tint(fraction < 0.6 ? .green : .orange)
      }
      if let chart {
        Charts.Chart(chart.points, id: \.date) { point in
          LineMark(x: .value("Time", point.date), y: .value("Value", point.value))
            .foregroundStyle(chart.color)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: .automatic(includesZero: false))
        .frame(height: 34)
        Text(chart.caption).font(.caption2).foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(8)
    .background(.quaternary, in: .rect(cornerRadius: 8))
    .accessibilityElement(children: .combine)
  }
}
