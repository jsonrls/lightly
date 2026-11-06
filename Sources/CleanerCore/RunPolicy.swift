import Foundation

/// The decisions that lead to deletion, kept pure so they can be tested without running the app.
public enum RunPolicy {
  public static let dryRunReportFlag = "--dry-run-report"

  /// Live needs all three, so any doubt is a dry run: `MACCLEANER_DRY_RUN=0` counts as set.
  public static func mode(arguments: [String], environment: [String: String], bundleLive: Bool) -> DeletionGateway.Mode {
    let override = !(environment["MACCLEANER_DRY_RUN"] ?? "").isEmpty
    return bundleLive && !override && !arguments.contains(dryRunReportFlag) ? .live : .dryRun
  }

  /// Stamps a fresh state so nothing is cleaned at first launch. Returns true when the state changed.
  public static func stampFirstLaunch(_ state: inout AppState, now: Date) -> Bool {
    guard state.lastScheduledRun == nil else { return false }
    state.lastScheduledRun = now
    return true
  }

  /// Restamps after the clock moved back, then says whether a scheduled run is due.
  /// `unsaved` blocks the run: its record could be lost, along with any pause waiting to be written.
  public static func scheduleCheck(_ state: inout AppState, unsaved: Bool, now: Date, calendar: Calendar) -> (restamped: Bool, shouldRun: Bool) {
    var restamped = false
    if let last = state.lastScheduledRun, last > now {
      state.lastScheduledRun = now
      restamped = true
    }
    let due = Scheduler.shouldRun(now: now, lastRun: state.lastScheduledRun, paused: state.paused, calendar: calendar)
    return (restamped, !unsaved && due)
  }

  /// Resuming stamps the schedule: catch-up is for a Mac that was asleep or off, not one the owner paused.
  public static func togglePause(_ state: inout AppState, now: Date) {
    state.paused.toggle()
    if !state.paused { state.lastScheduledRun = now }
  }

  /// `run` came from a snapshot taken before the clean, so anything the app changed during the run wins.
  /// A lost pause or resume stamp would turn into a clean the owner stopped.
  public static func merge(run: AppState, current: AppState, now: Date) -> AppState {
    var merged = run
    merged.paused = current.paused
    merged.diskSamples = current.diskSamples
    merged.lastScheduledRun = [run.lastScheduledRun, current.lastScheduledRun].compactMap { $0 }.max()
    merged.prune(now: now)
    return merged
  }
}
