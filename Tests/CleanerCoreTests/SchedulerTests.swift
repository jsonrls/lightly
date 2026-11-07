import Foundation
import Testing
@testable import CleanerCore

struct SchedulerTests {
  let cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Asia/Manila")!
    return c
  }()

  func at(_ s: String) -> Date {
    let f = DateFormatter()
    f.calendar = cal
    f.timeZone = cal.timeZone
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.date(from: s)!
  }

  func run(now: String, last: String?, paused: Bool = false) -> Bool {
    Scheduler.shouldRun(now: at(now), lastRun: last.map(at), paused: paused, interval: CleanSettings().interval)
  }

  @Test func neverStampedDoesNotRun() { #expect(!run(now: "2026-11-06 12:00", last: nil)) }
  @Test func pausedDoesNotRun() { #expect(!run(now: "2026-11-06 12:00", last: "2026-11-03 12:00", paused: true)) }

  @Test func runsEveryHourByDefaultNotBefore() {
    #expect(!run(now: "2026-11-06 09:59", last: "2026-11-06 09:00"))
    #expect(run(now: "2026-11-06 10:00", last: "2026-11-06 09:00"))
  }

  @Test(arguments: CleanSettings.intervalChoices)
  func everyChoiceRunsOnItsInterval(hours: Int) {
    let now = at("2026-11-06 12:00")
    var state = AppState()
    state.settings.intervalHours = hours
    state.lastScheduledRun = now - TimeInterval(hours) * 3600 + 60
    #expect(!RunPolicy.scheduleCheck(&state, unsaved: false, now: now).shouldRun)
    state.lastScheduledRun = now - TimeInterval(hours) * 3600
    #expect(RunPolicy.scheduleCheck(&state, unsaved: false, now: now).shouldRun)
  }

  @Test func runsAtAnyHourOfTheDay() { #expect(run(now: "2026-11-06 22:30", last: "2026-11-06 19:30")) }
  @Test func catchesUpAfterSleep() { #expect(run(now: "2026-11-06 08:00", last: "2026-11-03 03:00")) }
  @Test func clockMovedBackDoesNotRun() { #expect(!run(now: "2026-11-06 12:00", last: "2026-11-07 03:00")) }

  @Test func weeklyBoundary() {
    let now = at("2026-11-13 03:00")
    #expect(Scheduler.weeklyDue(now: now, lastWeeklyRun: nil))
    #expect(!Scheduler.weeklyDue(now: now, lastWeeklyRun: now - 6 * Limits.day))
    #expect(Scheduler.weeklyDue(now: now, lastWeeklyRun: now - 7 * Limits.day))
  }
}
