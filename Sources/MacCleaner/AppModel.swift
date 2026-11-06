import AppKit
import CleanerCore
import Observation
import ServiceManagement

enum Launch {
  static let isDryRunReport = CommandLine.arguments.contains("--dry-run-report")

  /// The one switch between a harmless launch and real deletion. Read it before anything else runs.
  static let mode: DeletionGateway.Mode = {
    #if DEBUG
    return .dryRun
    #else
    return isDryRunReport || ProcessInfo.processInfo.environment["MACCLEANER_DRY_RUN"] == "1" ? .dryRun : .live
    #endif
  }()
}

private func writeDryRunList(_ touched: [URL], to directory: URL) throws -> URL {
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let file = directory.appending(path: "dry-run.txt")
  let lines = touched.map { $0.path(percentEncoded: false) + "\n" }.joined()
  try lines.write(to: file, atomically: true, encoding: .utf8)
  return file
}

/// Hardcodes `.dryRun` instead of reading `Launch.mode`, so this path can never delete.
func runDryRunReport() -> Never {
  let directory = Store.defaultDirectory()
  var state = Store(directory: directory).load()
  let (record, touched) = CleanSession.run(env: CleanEnvironment.live(mode: .dryRun), state: &state, now: Date(), manual: true)
  do {
    let file = try writeDryRunList(touched, to: directory)
    print(file.path(percentEncoded: false))
    print("\(record.totalBytes) bytes")
    exit(0)
  } catch {
    NSLog("Could not write dry-run.txt: \(error)")
    exit(1)
  }
}

@MainActor @Observable final class AppModel {
  var stats: StatsSnapshot
  var samples: [(date: Date, stats: StatsSnapshot)] = []  // last 60 minutes
  var state = AppState()
  var isCleaning = false
  var trashAccess: Bool
  private(set) var dryRunRecord: RunRecord?
  var lastRecord: RunRecord? { dryRunRecord ?? state.history.last }

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
    state = Store(directory: storeDirectory).load()
    if state.lastScheduledRun == nil {  // so nothing is cleaned at first launch
      state.lastScheduledRun = Date()
      save()
    }
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
    if Bundle.main.bundleURL.pathExtension == "app", SMAppService.mainApp.status == .notRegistered {
      do { try SMAppService.mainApp.register() } catch { NSLog("Login item not registered: \(error)") }
    }
  }

  func cleanNow() { clean(manual: true) }

  func togglePause() {
    state.paused.toggle()
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
    do { try Store(directory: storeDirectory).save(state) } catch { NSLog("State not saved: \(error)") }
  }

  private func sampleStats() {
    let now = Date()
    stats = systemStats.sample()
    samples.append((now, stats))
    samples.removeAll { $0.date < now - 3600 }
    let sampledToday = state.diskSamples.last.map { Calendar.current.isDate($0.day, inSameDayAs: now) } ?? false
    if !sampledToday, stats.diskTotalBytes > 0 {  // a total of 0 means the read failed
      state.diskSamples.append(DiskSample(day: Calendar.current.startOfDay(for: now), freeBytes: stats.diskFreeBytes))
      save()
    }
  }

  private func checkSchedule() {
    trashAccess = TrashRule.hasAccess(trashDir: trashDir)
    guard mode == .live, !isCleaning else { return }
    let now = Date()
    if let last = state.lastScheduledRun, last > now {  // clock moved back
      state.lastScheduledRun = now
      save()
    }
    if Scheduler.shouldRun(now: now, lastRun: state.lastScheduledRun, paused: state.paused, calendar: .current) {
      clean(manual: false)
    }
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
        // Both can change during the run, and a lost pause would turn into a clean the owner stopped.
        var merged = next
        merged.paused = state.paused
        merged.diskSamples = state.diskSamples
        merged.prune(now: now)
        state = merged
        save()
      } else {
        dryRunRecord = record
        do { _ = try writeDryRunList(touched, to: storeDirectory) } catch { NSLog("Could not write dry-run.txt: \(error)") }
      }
    }
  }
}
