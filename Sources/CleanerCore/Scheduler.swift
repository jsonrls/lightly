import Foundation

public enum Scheduler {
  /// Deletion runs unattended, so every doubt answers false: paused, never stamped, clock behind the stamp, or no computable boundary.
  public static func shouldRun(now: Date, lastRun: Date?, paused: Bool, calendar: Calendar) -> Bool {
    guard !paused, let lastRun else { return false }
    if lastRun > now { return false }  // clock moved back: wait until the app restamps
    func three(of day: Date) -> Date? {
      calendar.date(bySettingHour: Limits.runHour, minute: 0, second: 0, of: day)
    }
    guard var boundary = three(of: now) else { return false }
    if boundary > now {
      guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
            let prev = three(of: yesterday) else { return false }
      boundary = prev
    }
    return boundary > lastRun
  }

  public static func weeklyDue(now: Date, lastWeeklyRun: Date?) -> Bool {
    guard let last = lastWeeklyRun else { return true }
    return now.timeIntervalSince(last) >= Limits.weekly
  }
}
