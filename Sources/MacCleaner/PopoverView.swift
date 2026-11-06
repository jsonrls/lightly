import CleanerCore
import SwiftUI

struct PopoverView: View {
  let model: AppModel
  @State private var expanded = false
  @Environment(\.openWindow) private var openWindow
  @Environment(\.dismiss) private var dismiss
  @State private var window: NSWindow?

  var body: some View {
    GlassEffectContainer(spacing: 4) {
      VStack(alignment: .leading, spacing: 10) {
        header
        StatusLines(model: model)
        disk
        gauges
        lastClean
        if !model.trashAccess { trashNotice }
        actions
      }
    }
    .padding(14)
    .frame(width: 300)
    .background(WindowReader(window: $window))
  }

  private var header: some View {
    HStack(spacing: 8) {
      Image(systemName: "sparkles").foregroundStyle(.tint)
      Text("Mac Cleaner").font(.headline)
      Spacer()
      gearMenu
      Button { NSApplication.shared.terminate(nil) } label: {
        Image(systemName: "power").frame(width: 30, height: 30).contentShape(.circle)
      }
      .buttonStyle(.plain)
      .glassEffect(.regular.interactive(), in: .circle)
      .disabled(model.isCleaning)  // quitting mid-clean would repeat the run at next launch
      .help("Quit Mac Cleaner")
      .accessibilityLabel("Quit Mac Cleaner")
    }
  }

  private var disk: some View {
    let stats = model.stats
    let used = stats.diskTotalBytes > 0 ? 1 - Double(stats.diskFreeBytes) / Double(stats.diskTotalBytes) : 0
    return HStack(spacing: 14) {
      Ring(fraction: used, color: pressureColor(used), lineWidth: 8) {
        Text(Format.percent(used)).font(.caption.weight(.semibold))
      }
      .frame(width: 64, height: 64)
      VStack(alignment: .leading, spacing: 1) {
        Text("Disk").font(.caption).foregroundStyle(.secondary)
        Text(Format.bytes(stats.diskFreeBytes)).font(.title2.weight(.semibold)).monospacedDigit()
        Text("free of \(Format.bytes(stats.diskTotalBytes))").font(.caption).foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
    .padding(12)
    .glassEffect(.regular, in: .rect(cornerRadius: 16))
    .accessibilityElement(children: .combine)
  }

  private var gauges: some View {
    let stats = model.stats
    return HStack(spacing: 8) {
      GaugeTile(title: "Memory", fraction: stats.memoryUsedFraction, color: pressureColor(stats.memoryUsedFraction))
      GaugeTile(title: "CPU", fraction: stats.cpuFraction, color: pressureColor(stats.cpuFraction))
      if let battery = stats.batteryFraction {
        GaugeTile(title: "Battery", fraction: battery, color: batteryColor(battery))
      }
    }
  }

  private var lastClean: some View {
    VStack(spacing: 6) {
      Button { withAnimation(.snappy) { expanded.toggle() } } label: {
        HStack {
          VStack(alignment: .leading, spacing: 1) {
            Text("Last clean").font(.caption).foregroundStyle(.secondary)
            Text(model.lastRecord.map(summary) ?? "Never").font(.callout.weight(.medium))
          }
          Spacer()
          if model.unsaved || model.lastRecord?.hasErrors == true {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(.yellow)
              .accessibilityLabel(model.unsaved ? "Could not save settings" : "Finished with errors")
          }
          if model.lastRecord != nil {
            Image(systemName: "chevron.right")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
              .rotationEffect(.degrees(expanded ? 90 : 0))
          }
        }
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .disabled(model.lastRecord == nil)

      InsightLines(model: model)

      if expanded, let record = model.lastRecord {
        CategoryRows(record: record)
      }
    }
    .padding(12)
    .glassEffect(.regular, in: .rect(cornerRadius: 16))
    .task(id: model.lastRecord?.date) { await model.explainLastRecord() }
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
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
    }
  }

  private var actions: some View {
    VStack(spacing: 8) {
      Button { model.cleanNow() } label: {
        Label(model.isCleaning ? "Cleaning…" : "Clean now", systemImage: "sparkles").frame(maxWidth: .infinity)
      }
      .buttonStyle(.glassProminent)
      .disabled(model.isCleaning)
      Button(action: openFullView) {
        Label("Open full view", systemImage: "macwindow").frame(maxWidth: .infinity)
      }
      .buttonStyle(.glass)
    }
    .buttonBorderShape(.capsule)
    .controlSize(.large)
  }

  private func openFullView() {
    openWindow(id: "full")
    NSApp.activate()  // an LSUIElement app is never frontmost on its own
    dismiss()
    window?.close()  // shortcut: dismiss alone could not be proven on a menu bar window, drop this once it is
  }

  private var gearMenu: some View {
    Menu {
      Button(model.state.paused ? "Resume auto-clean" : "Pause auto-clean") { model.togglePause() }
    } label: {
      Image(systemName: "gearshape")
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .frame(width: 30, height: 30)
    .glassEffect(.regular.interactive(), in: .circle)
    .accessibilityLabel("Settings")
  }
}

/// Finds the window this view sits in, so it can close exactly that one.
private struct WindowReader: NSViewRepresentable {
  @Binding var window: NSWindow?

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    DispatchQueue.main.async { window = view.window }  // the view has no window until it is attached
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {}
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

/// The Apple Intelligence description of the last run, labelled because it can be wrong.
struct InsightLines: View {
  let model: AppModel

  var body: some View {
    if let insight = model.insight {
      VStack(alignment: .leading, spacing: 3) {
        Text(insight.headline)
        if !insight.problem.isEmpty { Text(insight.problem) }
        Label("Apple Intelligence", systemImage: "apple.intelligence").font(.caption2).foregroundStyle(.tertiary)
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
    }
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
