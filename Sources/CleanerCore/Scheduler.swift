import Foundation

public enum Scheduler {
  /// Deletion runs unattended, so every doubt answers false: paused, never stamped, clock behind the stamp, or no computable boundary.
  public static func shouldRun(now: Date, lastRun: Date?, paused: Bool, interval: TimeInterval) -> Bool {
    guard !paused, let lastRun else { return false }
    if lastRun > now { return false }  // clock moved back: wait until the app restamps
    return now.timeIntervalSince(lastRun) >= interval
  }

  public static func weeklyDue(now: Date, lastWeeklyRun: Date?) -> Bool {
    guard let last = lastWeeklyRun else { return true }
    return now.timeIntervalSince(last) >= Limits.weekly
  }
}
