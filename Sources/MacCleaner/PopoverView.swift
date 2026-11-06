import CleanerCore
import SwiftUI

struct PopoverView: View {
  let model: AppModel
  @State private var expanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      tiles
      lastClean
      if !model.trashAccess { trashNotice }
      Button { model.cleanNow() } label: { Text("Clean now").frame(maxWidth: .infinity) }
        .buttonStyle(.borderedProminent)
        .disabled(model.isCleaning)
      HStack {
        // The window arrives with the full view task.
        Button {} label: { Text("Open full view").frame(maxWidth: .infinity) }
          .disabled(true)
        gearMenu
      }
    }
    .padding(14)
    .frame(width: 280)
  }

  private var tiles: some View {
    let stats = model.stats
    let used = stats.diskTotalBytes > 0 ? 1 - Double(stats.diskFreeBytes) / Double(stats.diskTotalBytes) : nil
    return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
      StatTile(title: "DISK", value: "\(Format.bytes(stats.diskFreeBytes)) free", fraction: used)
      StatTile(title: "MEMORY", value: "\(Format.percent(stats.memoryUsedFraction)) used", fraction: stats.memoryUsedFraction)
      StatTile(title: "CPU", value: Format.percent(stats.cpuFraction), fraction: nil)
      if let battery = stats.batteryFraction {
        StatTile(title: "BATTERY", value: Format.percent(battery), fraction: nil)
      }
    }
  }

  private var lastClean: some View {
    VStack(spacing: 4) {
      Button { expanded.toggle() } label: {
        HStack {
          Text("Last clean")
          Spacer()
          if model.lastRecord?.hasErrors == true {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(.yellow)
              .accessibilityLabel("Finished with errors")
          }
          Text(model.lastRecord.map(summary) ?? "Never").foregroundStyle(.secondary)
        }
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .disabled(model.lastRecord == nil)

      if expanded, let record = model.lastRecord {
        ForEach(record.results, id: \.category) { result in
          HStack {
            Text(result.category.displayName)
            Spacer()
            Text(Format.bytes(result.bytesFreed))
          }
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }
    }
  }

  private func summary(_ record: RunRecord) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .short
    formatter.doesRelativeDateFormatting = true  // "Today" like the mockup
    return "\(formatter.string(from: record.date)) · \(Format.bytes(record.totalBytes))"
  }

  private var trashNotice: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Trash is skipped. Grant Full Disk Access to include it.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Button("Open Settings") { model.openFullDiskAccessSettings() }
    }
  }

  private var gearMenu: some View {
    Menu {
      Button(model.state.paused ? "Resume auto-clean" : "Pause auto-clean") { model.togglePause() }
      Button("Quit") { NSApplication.shared.terminate(nil) }
    } label: {
      Image(systemName: "gearshape")
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .accessibilityLabel("Settings")
  }
}
