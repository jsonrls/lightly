import CleanerCore
import SwiftUI

struct PopoverView: View {
  let model: AppModel
  @State private var expanded = false
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      StatusLines(model: model)
      tiles
      lastClean
      if !model.trashAccess { trashNotice }
      Button { model.cleanNow() } label: { Text("Clean now").frame(maxWidth: .infinity) }
        .buttonStyle(.borderedProminent)
        .disabled(model.isCleaning)
      HStack {
        Button {
          openWindow(id: "full")
          NSApp.activate()  // an LSUIElement app is never frontmost on its own
        } label: { Text("Open full view").frame(maxWidth: .infinity) }
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
          if model.unsaved || model.lastRecord?.hasErrors == true {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(.yellow)
              .accessibilityLabel(model.unsaved ? "Could not save settings" : "Finished with errors")
          }
          Text(model.lastRecord.map(summary) ?? "Never").foregroundStyle(.secondary)
        }
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .disabled(model.lastRecord == nil)

      if expanded, let record = model.lastRecord {
        CategoryRows(record: record)
      }
    }
  }

  private func summary(_ record: RunRecord) -> String {
    "\(shortDate(record.date)) · \(Format.bytes(record.totalBytes))"
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

func shortDate(_ date: Date) -> String {
  let formatter = DateFormatter()
  formatter.dateStyle = .short
  formatter.timeStyle = .short
  formatter.doesRelativeDateFormatting = true  // "Today" like the mockup
  return formatter.string(from: date)
}

/// The dry-run and paused lines, shared by the menu bar window and the full view.
struct StatusLines: View {
  let model: AppModel

  var body: some View {
    if model.mode == .dryRun { line("Dry run: nothing is deleted") }
    if model.state.paused { line("Auto-clean paused") }
  }

  private func line(_ text: String) -> some View {
    Text(text).font(.caption.weight(.semibold)).foregroundStyle(.orange)
  }
}

struct CategoryRows: View {
  let record: RunRecord

  var body: some View {
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
