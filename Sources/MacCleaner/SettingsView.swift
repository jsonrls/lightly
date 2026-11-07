import AppKit
import CleanerCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
  let model: AppModel
  @State private var keptHeight: CGFloat = 0

  var body: some View {
    GlassEffectContainer(spacing: 4) {
      VStack(alignment: .leading, spacing: 10) {
        StatusLines(model: model)
        general
        schedule
        whatToClean
        alwaysKept
        permissions
        about
      }
      .padding(14)
    }
    .font(.callout)
    .controlSize(.small)
    .frame(width: 400)
    .fixedSize(horizontal: false, vertical: true)  // the window is as tall as its content, so nothing scrolls
    .containerBackground(.thinMaterial, for: .window)
  }

  private var general: some View {
    card {
      row("Open at login", detail: loginDetail, isOn: Binding(get: { model.state.settings.openAtLogin }, set: { model.setOpenAtLogin($0) }))
      if model.loginStatus == .requiresApproval {
        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
          .buttonStyle(.glass)
          .buttonBorderShape(.capsule)
      }
      Divider()
      row("Use Apple Intelligence",
          detail: CleanInsight.isModelAvailable ? "Summaries and chat with Dusty, on this Mac only" : "Not available on this Mac",
          isOn: setting(\.useAppleIntelligence))
        .disabled(!CleanInsight.isModelAvailable)
    }
  }

  private var loginDetail: String? {
    model.loginStatus == .requiresApproval ? "Needs your approval in System Settings" : nil
  }

  private var schedule: some View {
    section("Auto-clean") {
      row("Clean automatically", isOn: Binding(
        get: { !model.state.paused },
        set: { if $0 == model.state.paused { model.togglePause() } }))
      Divider()
      HStack {
        Text("Clean")
        Spacer()
        Picker("Clean", selection: setting(\.intervalHours)) {
          ForEach(CleanSettings.intervalChoices, id: \.self) { Text(label(hours: $0)).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
      }
    }
  }

  private func label(hours: Int) -> String {
    switch hours {
    case 1: "Every hour"
    case 24: "Once a day"
    default: "Every \(hours) hours"
    }
  }

  private var whatToClean: some View {
    section("What to clean") {
      ForEach(Array(CleanCategory.allCases.enumerated()), id: \.element) { index, category in
        if index > 0 { Divider() }
        row(category.displayName, detail: detail(category), isOn: Binding(
          get: { !model.state.settings.disabled.contains(category) },
          set: { on in model.updateSettings { if on { $0.disabled.remove(category) } else { $0.disabled.insert(category) } } }))
      }
    }
  }

  private func detail(_ category: CleanCategory) -> String {
    switch category {
    case .appCaches: "Skips apps that are open"
    case .logs: "Older than 7 days, crash reports are kept"
    case .trash: "Deleted for good, needs Full Disk Access"
    case .leftovers: "Apps gone for 30 days, moved to the Trash first"
    case .devCaches: "npm, yarn, pnpm, pip, Homebrew and Xcode, weekly"
    case .docker: "Build cache and dangling images, weekly"
    }
  }

  private var alwaysKept: some View {
    section("Always kept") {
      if !model.state.settings.keptFolders.isEmpty {
        ScrollView {
          VStack(alignment: .leading, spacing: 5) {
            ForEach(model.state.settings.keptFolders, id: \.self) { path in
              HStack {
                Text(shortPath(path)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button { model.updateSettings { $0.keptFolders.removeAll { $0 == path } } } label: {
                  Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop keeping \(shortPath(path))")
              }
              Divider()
            }
          }
          .fixedSize(horizontal: false, vertical: true)
          .onGeometryChange(for: CGFloat.self, of: \.size.height) { keptHeight = $0 }
        }
        .frame(height: min(keptHeight, 70))  // a long list scrolls here, so the window stays on screen
      }
      Text("Never cleaned, along with Documents, Desktop, Downloads, Photos, Mail and browser profiles.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Button("Add…", action: addFolders)
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .disabled(model.isCleaning)  // a clean in progress uses the list it started with
    }
  }

  private func shortPath(_ path: String) -> String {
    let home = URL.homeDirectory.path(percentEncoded: false)
    return path.hasPrefix(home) ? "~/" + path.dropFirst(home.count) : path
  }

  private func addFolders() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = true
    panel.showsHiddenFiles = true
    panel.directoryURL = URL.homeDirectory.appending(path: "Library/Caches")
    panel.prompt = "Keep"
    NSApp.activate()
    guard panel.runModal() == .OK else { return }
    let paths = panel.urls.map { $0.path(percentEncoded: false) }
    model.updateSettings { settings in
      settings.keptFolders += paths.filter { !settings.keptFolders.contains($0) }
    }
  }

  private var permissions: some View {
    section("Permissions") {
      HStack {
        VStack(alignment: .leading, spacing: 1) {
          Text("Full Disk Access")
          Text(model.trashAccess ? "On, the Trash is included" : "Off, the Trash is skipped")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Open Settings") { model.openFullDiskAccessSettings() }
          .buttonStyle(.glass)
          .buttonBorderShape(.capsule)
      }
    }
  }

  private var about: some View {
    card {
      HStack(spacing: 10) {
        Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 26, height: 26)
        VStack(alignment: .leading, spacing: 1) {
          Text("Lightly").font(.callout.weight(.semibold))
          Text("Version \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "dev")")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if let url = URL(string: "https://github.com/jsonrls/mac-cleaner") {
          Link("View on GitHub", destination: url)
        }
      }
    }
  }

  private func setting<Value>(_ keyPath: WritableKeyPath<CleanSettings, Value>) -> Binding<Value> {
    Binding(
      get: { model.state.settings[keyPath: keyPath] },
      set: { value in model.updateSettings { $0[keyPath: keyPath] = value } })
  }

  private func row(_ title: String, detail: String? = nil, isOn: Binding<Bool>) -> some View {
    HStack {
      VStack(alignment: .leading, spacing: 1) {
        Text(title)
        if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
      }
      Spacer()
      Toggle(title, isOn: isOn).toggleStyle(.switch).labelsHidden().controlSize(.mini)
    }
  }

  private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.caption.weight(.semibold))
      card(content)
    }
  }

  private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 5, content: content)
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .glassEffect(.regular, in: .rect(cornerRadius: 12))
  }
}
