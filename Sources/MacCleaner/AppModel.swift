import AppKit
import CleanerCore
import Observation
import ServiceManagement

enum Launch {
  static let isDryRunReport = CommandLine.arguments.contains(RunPolicy.dryRunReportFlag)

  /// The one switch between a harmless launch and real deletion. Read it before anything else runs.
  static let mode: DeletionGateway.Mode = {
    #if DEBUG
    return .dryRun
    #else
    return RunPolicy.mode(arguments: CommandLine.arguments, environment: ProcessInfo.processInfo.environment,
                          bundleLive: Bundle.main.object(forInfoDictionaryKey: "MacCleanerLive") as? Bool == true)
    #endif
  }()
}

let trashWarning = "# Trash not readable: list is incomplete. Grant Full Disk Access to include it."

private func writeDryRunList(_ touched: [URL], to directory: URL, warning: String? = nil) throws -> URL {
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let file = directory.appending(path: "dry-run.txt")
  let lines = (warning.map { $0 + "\n" } ?? "") + touched.map { $0.path(percentEncoded: false) + "\n" }.joined()
  try lines.write(to: file, atomically: true, encoding: .utf8)
  return file
}

/// Hardcodes `.dryRun` instead of reading `Launch.mode`, so this path can never delete.
func runDryRunReport() -> Never {
  let directory = Store.defaultDirectory()
  var state = Store(directory: directory).peek()
  let (record, touched) = CleanSession.run(env: CleanEnvironment.live(mode: .dryRun), state: &state, now: Date(), manual: true)
  do {
    let warning = TrashRule.hasAccess(trashDir: URL.homeDirectory.appending(path: ".Trash", directoryHint: .isDirectory)) ? nil : trashWarning
    let file = try writeDryRunList(touched, to: directory, warning: warning)
    if let warning { print(warning) }
    print(file.path(percentEncoded: false))
    print("\(record.totalBytes) bytes")
    exit(0)
  } catch {
    NSLog("Could not write dry-run.txt: %@", "\(error)")
    exit(1)
  }
}

@MainActor @Observable final class AppModel {
  var stats: StatsSnapshot
  var state = AppState()
  var isCleaning = false
  var trashAccess: Bool
  private(set) var unsaved = false  // the last save failed; retried on each schedule check
  private(set) var dryRunRecord: RunRecord?
  var lastRecord: RunRecord? { dryRunRecord ?? state.history.last }
  private var explained: (date: Date, insight: CleanInsight)?
  var insight: CleanInsight? {
    state.settings.useAppleIntelligence && explained?.date == lastRecord?.date ? explained?.insight : nil
  }
  private(set) var loginStatus = SMAppService.mainApp.status

  /// Called when a window shows the record, so a run nobody looks at costs nothing.
  func explainLastRecord() async {
    guard state.settings.useAppleIntelligence, let record = lastRecord, explained?.date != record.date else { return }
    if let insight = await CleanInsight.explain(record) { explained = (record.date, insight) }
  }

  let mode: DeletionGateway.Mode
  private let systemStats: SystemStats
  private let storeDirectory = Store.defaultDirectory()
  private let trashDir = URL.homeDirectory.appending(path: ".Trash", directoryHint: .isDirectory)

  init(mode: DeletionGateway.Mode) {
    self.mode = mode
    let home = URL.homeDirectory
    systemStats = SystemStats(volume: DeletionGateway.Hooks.live.volumeOf(home) ?? home)
    stats = systemStats.sample()
    trashAccess = TrashRule.hasAccess(trashDir: trashDir)
  }

  func start() {
    let store = Store(directory: storeDirectory)
    state = mode == .live ? store.load() : store.peek()
    if RunPolicy.stampFirstLaunch(&state, now: Date()) { save() }
    Task {
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(10))
        sampleStats()
      }
    }
    Task {
      while !Task.isCancelled {
        checkSchedule()
        try? await Task.sleep(for: .seconds(60))
      }
    }
    guard mode == .live else { return }
    Task {
      for await _ in NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.didWakeNotification) {
        checkSchedule()
      }
    }
    applyLoginItem()
  }

  func cleanNow() { clean(manual: true) }

  func updateSettings(_ change: (inout CleanSettings) -> Void) {
    change(&state.settings)
    save()
  }

  func setOpenAtLogin(_ on: Bool) {
    updateSettings { $0.openAtLogin = on }
    applyLoginItem()
  }

  /// Live only: a dry-run build must never leave a login item behind.
  private func applyLoginItem() {
    guard mode == .live, Bundle.main.bundleURL.pathExtension == "app" else { return }
    let service = SMAppService.mainApp
    do {
      if state.settings.openAtLogin, service.status == .notRegistered { try service.register() }
      if !state.settings.openAtLogin, service.status == .enabled { try service.unregister() }
    } catch {
      NSLog("Login item not changed: %@", "\(error)")
    }
    loginStatus = service.status
  }

  func togglePause() {
    RunPolicy.togglePause(&state, now: Date())
    save()
  }

  func openFullDiskAccessSettings() {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
    NSWorkspace.shared.open(url)
  }

  /// The only caller of `Store.save`: a dry-run process must leave no state behind,
  /// or its `lastScheduledRun` stamp would make the first live launch clean at once.
  private func save() {
    guard mode == .live else { return }
    do {
      try Store(directory: storeDirectory).save(state)
      unsaved = false
    } catch {
      unsaved = true
      NSLog("State not saved: %@", "\(error)")
    }
  }

  private func sampleStats() {
    let now = Date()
    stats = systemStats.sample()
    let sampledToday = state.diskSamples.last.map { Calendar.current.isDate($0.day, inSameDayAs: now) } ?? false
    if !sampledToday, stats.diskTotalBytes > 0 {  // a total of 0 means the read failed
      state.diskSamples.append(DiskSample(day: Calendar.current.startOfDay(for: now), freeBytes: stats.diskFreeBytes))
      save()
    }
  }

  private func checkSchedule() {
    trashAccess = TrashRule.hasAccess(trashDir: trashDir)
    guard mode == .live, !isCleaning else { return }
    if unsaved { save() }
    let check = RunPolicy.scheduleCheck(&state, unsaved: unsaved, now: Date())
    if check.restamped { save() }
    if check.shouldRun { clean(manual: false) }
  }

  private func clean(manual: Bool) {
    guard !isCleaning else { return }
    isCleaning = true
    let mode = mode, snapshot = state, now = Date()
    Task {
      let (next, record, touched) = await Task.detached(priority: .utility) {
        var next = snapshot
        let (record, touched) = CleanSession.run(env: CleanEnvironment.live(mode: mode), state: &next, now: now, manual: manual)
        return (next, record, touched)
      }.value
      isCleaning = false
      if mode == .live {
        state = RunPolicy.merge(run: next, current: state, now: now)
        save()
      } else {
        dryRunRecord = record
        do { _ = try writeDryRunList(touched, to: storeDirectory) } catch { NSLog("Could not write dry-run.txt: %@", "\(error)") }
      }
    }
  }
}
