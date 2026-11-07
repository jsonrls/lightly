import CleanerCore
import SwiftUI

struct FullView: View {
  let model: AppModel
  let ask: AskModel
  @State private var page = 0

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      StatusLines(model: model)
      tiles
      HStack(alignment: .top, spacing: 10) {
        lastClean
        history
      }
      AskPanel(model: model, ask: ask)
      footer
    }
    .padding(16)
    .frame(minWidth: 560, alignment: .top)
    .fixedSize(horizontal: false, vertical: true)  // the window is as tall as its content, so no blank space
    .containerBackground(.thinMaterial, for: .window)  // glass needs something to refract
  }

  private var tiles: some View {
    let stats = model.stats
    let used = stats.diskTotalBytes > 0 ? 1 - Double(stats.diskFreeBytes) / Double(stats.diskTotalBytes) : 0
    return GlassEffectContainer(spacing: 4) {
      HStack(spacing: 10) {
        gauge("Disk", "\(Format.bytes(stats.diskFreeBytes)) free", used, pressureColor(used))
        gauge("Memory", "used", stats.memoryUsedFraction, pressureColor(stats.memoryUsedFraction))
        gauge("CPU", "in use", stats.cpuFraction, pressureColor(stats.cpuFraction))
        if let battery = stats.batteryFraction {
          gauge("Battery", "charged", battery, batteryColor(battery))
        }
      }
    }
  }

  private func gauge(_ title: String, _ detail: String, _ fraction: Double, _ color: Color) -> GaugeTile {
    GaugeTile(title: title, detail: detail, fraction: fraction, color: color, size: 84, lineWidth: 8, font: .callout.weight(.semibold))
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
      InsightLines(model: model)
      if let record = model.lastRecord { CategoryRows(record: record) }
    }
    .task(id: model.lastRecord?.date) { await model.explainLastRecord() }
  }

  private var history: some View {
    // A dry run keeps its record out of state.history, so list it first.
    let runs = (model.dryRunRecord.map { [$0] } ?? []) + model.state.history.reversed()
    let shown = Page(runs, index: page, size: 5)
    let month = Format.monthlyTotal(model.state.history, now: Date(), calendar: .current)
    return panel {
      HStack {
        Text("Cleaning history")
        Spacer()
        Text("\(Format.bytes(month)) this month").foregroundStyle(.secondary)
      }
      .font(.callout.weight(.semibold))
      ForEach(shown.items, id: \.date) { run in
        HStack {
          Text(shortDate(run.date))
          Spacer()
          Text(Format.bytes(run.totalBytes))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      if shown.count > 1 {
        Spacer(minLength: 0)
        pager(shown)
      }
    }
  }

  private func pager(_ shown: Page<RunRecord>) -> some View {
    HStack(spacing: 8) {
      Spacer()
      Button { page = shown.index - 1 } label: { Image(systemName: "chevron.left") }
        .disabled(shown.index == 0)
        .accessibilityLabel("Newer runs")
      Text("\(shown.index + 1) of \(shown.count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
      Button { page = shown.index + 1 } label: { Image(systemName: "chevron.right") }
        .disabled(shown.index == shown.count - 1)
        .accessibilityLabel("Older runs")
    }
    .buttonStyle(.glass)
    .buttonBorderShape(.circle)
    .controlSize(.small)
  }

  private var footer: some View {
    GlassEffectContainer(spacing: 4) {
      HStack {
        Button("Clean now") { model.cleanNow() }
          .buttonStyle(.glassProminent)
          .disabled(model.isCleaning)
        Button(model.state.paused ? "Resume auto-clean" : "Pause auto-clean") { model.togglePause() }
          .buttonStyle(.glass)
      }
      .buttonBorderShape(.capsule)
      .controlSize(.large)
    }
  }

  private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 6, content: content)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .padding(12)
      .glassEffect(.regular, in: .rect(cornerRadius: 14))
  }
}
