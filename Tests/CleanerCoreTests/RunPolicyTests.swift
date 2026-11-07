import Foundation
import Testing
@testable import CleanerCore

struct RunPolicyTests {
  let cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Asia/Manila")!
    return c
  }()

  func at(_ hour: Int, day: Int = 6) -> Date {
    cal.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
  }

  // MARK: mode

  @Test(arguments: [true, false], [
    (env: [:], clear: true),
    (env: ["MACCLEANER_DRY_RUN": ""], clear: true),
    (env: ["MACCLEANER_DRY_RUN": "1"], clear: false),
    (env: ["MACCLEANER_DRY_RUN": "true"], clear: false),
    (env: ["MACCLEANER_DRY_RUN": "0"], clear: false),
    (env: ["MACCLEANER_DRY_RUN": "false"], clear: false),
    (env: ["OTHER": "1"], clear: true),
  ] as [(env: [String: String], clear: Bool)])
  func modeCombinations(bundleLive: Bool, environment: (env: [String: String], clear: Bool)) {
    let plain = ["/x/MacCleaner"], report = plain + ["--dry-run-report"]
    #expect(RunPolicy.mode(arguments: report, environment: environment.env, bundleLive: bundleLive) == .dryRun)
    let expected: DeletionGateway.Mode = bundleLive && environment.clear ? .live : .dryRun
    #expect(RunPolicy.mode(arguments: plain, environment: environment.env, bundleLive: bundleLive) == expected)
  }

  @Test func unarmedBundleIgnoresMistypedFlag() {
    #expect(RunPolicy.mode(arguments: ["/x", "--dry-run-reprot"], environment: [:], bundleLive: false) == .dryRun)
  }

  // MARK: first-launch stamp

  @Test func firstLaunchStampsNow() {
    var s = AppState()
    #expect(RunPolicy.stampFirstLaunch(&s, now: at(12)))
    #expect(s.lastScheduledRun == at(12))
  }

  @Test func laterLaunchKeepsStamp() {
    var s = AppState()
    s.lastScheduledRun = at(4)
    #expect(!RunPolicy.stampFirstLaunch(&s, now: at(12)))
    #expect(s.lastScheduledRun == at(4))
  }

  @Test func firstLaunchDoesNotRun() {
    var s = AppState()
    _ = RunPolicy.stampFirstLaunch(&s, now: at(12))
    #expect(!RunPolicy.scheduleCheck(&s, unsaved: false, now: at(12)).shouldRun)
  }

  // MARK: schedule check

  func dueState() -> AppState {
    var s = AppState()
    s.lastScheduledRun = at(4, day: 5)
    return s
  }

  @Test func dueRunGoes() {
    var s = dueState()
    let check = RunPolicy.scheduleCheck(&s, unsaved: false, now: at(12))
    #expect(check.shouldRun && !check.restamped)
    #expect(s == dueState())
  }

  @Test func unsavedStateSkipsDueRun() {
    var s = dueState()
    #expect(!RunPolicy.scheduleCheck(&s, unsaved: true, now: at(12)).shouldRun)
  }

  @Test func pausedSkipsDueRun() {
    var s = dueState()
    s.paused = true
    #expect(!RunPolicy.scheduleCheck(&s, unsaved: false, now: at(12)).shouldRun)
  }

  @Test func clockBackRestampsAndDoesNotRun() {
    var s = AppState()
    s.lastScheduledRun = at(12, day: 8)
    let check = RunPolicy.scheduleCheck(&s, unsaved: false, now: at(12))
    #expect(check.restamped && !check.shouldRun)
    #expect(s.lastScheduledRun == at(12))
  }

  @Test func clockBackStillRestampsWhileUnsaved() {
    var s = AppState()
    s.lastScheduledRun = at(12, day: 8)
    #expect(RunPolicy.scheduleCheck(&s, unsaved: true, now: at(12)).restamped)
  }

  // MARK: pause

  @Test func resumeStampsSoNoCatchUpRuns() {
    var s = dueState()
    s.paused = true
    RunPolicy.togglePause(&s, now: at(12))
    #expect(!s.paused)
    #expect(s.lastScheduledRun == at(12))
    #expect(!RunPolicy.scheduleCheck(&s, unsaved: false, now: at(12)).shouldRun)
  }

  @Test func pausingKeepsStamp() {
    var s = dueState()
    RunPolicy.togglePause(&s, now: at(12))
    #expect(s.paused)
    #expect(s.lastScheduledRun == dueState().lastScheduledRun)
  }

  // MARK: merge

  @Test func mergeTakesRunResultsAndCurrentPause() {
    var run = AppState()
    run.history = [RunRecord(date: at(12), manual: false, results: [])]
    run.lastScheduledRun = at(12)
    run.lastWeeklyRun = at(12)
    var current = AppState()
    current.paused = true
    current.lastScheduledRun = at(4)
    current.diskSamples = [DiskSample(day: at(0), freeBytes: 9)]
    let merged = RunPolicy.merge(run: run, current: current, now: at(12))
    #expect(merged.paused)
    #expect(merged.diskSamples == current.diskSamples)
    #expect(merged.history == run.history)
    #expect(merged.lastScheduledRun == at(12))
    #expect(merged.lastWeeklyRun == at(12))
  }

  @Test func mergeKeepsResumeStampFromDuringManualRun() {
    var run = AppState()
    run.lastScheduledRun = at(4, day: 5)
    var current = AppState()
    current.lastScheduledRun = at(12)
    #expect(RunPolicy.merge(run: run, current: current, now: at(11)).lastScheduledRun == at(12))
  }

  @Test func mergePrunesCurrentSamples() {
    var current = AppState()
    current.diskSamples = [DiskSample(day: at(12) - 31 * Limits.day, freeBytes: 1)]
    #expect(RunPolicy.merge(run: AppState(), current: current, now: at(12)).diskSamples.isEmpty)
  }
}
