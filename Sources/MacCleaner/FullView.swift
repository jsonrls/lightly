import CleanerCore
import SwiftUI

struct FullView: View {
  let model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      StatusLines(model: model)
      tiles
      HStack(alignment: .top, spacing: 10) {
        lastClean
        history
      }
      footer
    }
    .padding(16)
    .frame(minWidth: 560, minHeight: 420, alignment: .top)
  }

  private var tiles: some View {
    let stats = model.stats
    let minutes = model.samples
    let used = stats.diskTotalBytes > 0 ? 1 - Double(stats.diskFreeBytes) / Double(stats.diskTotalBytes) : nil
    let hour = "last 60 minutes"
    return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
      StatTile(title: "DISK", value: "\(Format.bytes(stats.diskFreeBytes)) free", fraction: used,
               chart: .init(points: model.state.diskSamples.map { ($0.day, Double($0.freeBytes)) }, color: .green, caption: "last 30 days"))
      StatTile(title: "MEMORY", value: "\(Format.percent(stats.memoryUsedFraction)) used", fraction: stats.memoryUsedFraction,
               chart: .init(points: minutes.map { ($0.date, $0.stats.memoryUsedFraction) }, color: .orange, caption: hour))
      StatTile(title: "CPU", value: Format.percent(stats.cpuFraction), fraction: nil,
               chart: .init(points: minutes.map { ($0.date, $0.stats.cpuFraction) }, color: .blue, caption: hour))
      if let battery = stats.batteryFraction {
        StatTile(title: "BATTERY", value: Format.percent(battery), fraction: nil,
                 chart: .init(points: minutes.compactMap { s in s.stats.batteryFraction.map { (s.date, $0) } }, color: .purple, caption: hour))
      }
    }
  }

  private var lastClean: some View {
    panel {
      HStack {
        Text("Last clean")
        Spacer()
        if let record = model.lastRecord {
          Text("\(shortDate(record.date)) · \(Format.bytes(record.totalBytes))").foregroundStyle(.secondary)
        } else {
          Text("Never").foregroundStyle(.secondary)
        }
      }
      .font(.callout.weight(.semibold))
      if let record = model.lastRecord { CategoryRows(record: record) }
    }
  }

  private var history: some View {
    // A dry run keeps its record out of state.history, so list it first.
    let runs = (model.dryRunRecord.map { [$0] } ?? []) + model.state.history.reversed()
    let month = Format.monthlyTotal(model.state.history, now: Date(), calendar: .current)
    return panel {
      HStack {
        Text("Cleaning history")
        Spacer()
        Text("\(Format.bytes(month)) this month").foregroundStyle(.secondary)
      }
      .font(.callout.weight(.semibold))
      ScrollView {
        VStack(spacing: 4) {
          ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
            HStack {
              Text(shortDate(run.date))
              Spacer()
              Text(Format.bytes(run.totalBytes))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
          }
        }
      }
    }
  }

  private var footer: some View {
    HStack {
      Button("Clean now") { model.cleanNow() }
        .buttonStyle(.borderedProminent)
        .disabled(model.isCleaning)
      Button(model.state.paused ? "Resume auto-clean" : "Pause auto-clean") { model.togglePause() }
    }
  }

  private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 6, content: content)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .padding(10)
      .background(.quaternary, in: .rect(cornerRadius: 8))
  }
}
