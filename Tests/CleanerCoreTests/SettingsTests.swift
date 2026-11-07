import Foundation
import Testing
@testable import CleanerCore

struct SettingsTests {
  let s = Sandbox()
  private var state: URL { s.url("store/state.json") }

  private func write(_ json: String) {
    s.dir("store")
    try! json.write(to: state, atomically: true, encoding: .utf8)
  }

  // The file written by the version before settings existed: it must never read as corrupt.
  private let oldFile = """
    {"diskSamples":[],"history":[{"date":"2026-11-06T15:15:04Z","manual":true,"results":[]}],
     "inventory":{"installed":["com.a.b"],"removed":{}},"lastScheduledRun":"2026-11-06T19:13:39Z","paused":false}
    """

  @Test func stateFromBeforeSettingsStillLoads() {
    write(oldFile)
    let loaded = Store(directory: s.url("store")).load()
    #expect(loaded.history.count == 1)
    #expect(!loaded.paused)
    #expect(loaded.settings == CleanSettings())
    #expect(!s.exists("store/state.corrupt.json"))
  }

  @Test func settingsSurviveASave() throws {
    let store = Store(directory: s.url("store"))
    var saved = AppState()
    saved.settings.intervalHours = 6
    saved.settings.disabled = [.docker]
    saved.settings.keptFolders = ["/tmp/keep"]
    saved.settings.openAtLogin = false
    saved.settings.useAppleIntelligence = false
    try store.save(saved)
    #expect(store.load().settings == saved.settings)
  }

  @Test func aMissingOrDamagedFieldFallsBackToTheDefault() {
    write(#"{"diskSamples":[],"history":[],"inventory":{"installed":[],"removed":{}},"paused":false,"storedSettings":{"intervalHours":6,"disabled":["futureThing"]}}"#)
    let loaded = Store(directory: s.url("store")).load()
    #expect(loaded.settings.intervalHours == 6)
    #expect(loaded.settings.disabled.isEmpty)
    #expect(loaded.settings.openAtLogin)
    #expect(!s.exists("store/state.corrupt.json"))
  }

  // One unknown category must not re-enable the ones the owner turned off.
  @Test func anUnknownCategoryKeepsTheKnownOnesDisabled() {
    write(#"{"diskSamples":[],"history":[],"inventory":{"installed":[],"removed":{}},"paused":false,"storedSettings":{"disabled":["trash","futureThing"]}}"#)
    #expect(Store(directory: s.url("store")).load().settings.disabled == [.trash])
  }

  // An empty kept list would delete what the owner kept, so a damaged one pauses like a damaged file.
  @Test func aDamagedKeptListPauses() {
    write(#"{"diskSamples":[],"history":[],"inventory":{"installed":[],"removed":{}},"paused":false,"storedSettings":{"keptFolders":["/k",1]}}"#)
    #expect(Store(directory: s.url("store")).load().paused)
    #expect(s.exists("store/state.corrupt.json"))
  }

  @Test func anIntervalThePickerCannotShowFallsBackToTheDefault() {
    write(#"{"diskSamples":[],"history":[],"inventory":{"installed":[],"removed":{}},"paused":false,"storedSettings":{"intervalHours":2}}"#)
    #expect(Store(directory: s.url("store")).load().settings.intervalHours == CleanSettings().intervalHours)
  }

  @Test func aDamagedIntervalCannotCleanInALoop() {
    var settings = CleanSettings()
    settings.intervalHours = 0
    #expect(settings.interval == 3600)
    settings.intervalHours = -5
    #expect(settings.interval == 3600)
  }

  @Test func defaultIsEveryThreeHours() {
    #expect(CleanSettings().interval == 3600)
    #expect(CleanSettings.intervalChoices == [1, 3, 6, 12, 24])
  }

  // Schedule
  @Test func scheduleFollowsTheChosenInterval() {
    let start = Date(timeIntervalSince1970: 1_000_000)
    var state = AppState()
    state.lastScheduledRun = start
    state.settings.intervalHours = 6
    #expect(!RunPolicy.scheduleCheck(&state, unsaved: false, now: start + 5 * 3600).shouldRun)
    #expect(RunPolicy.scheduleCheck(&state, unsaved: false, now: start + 6 * 3600).shouldRun)
  }

  @Test func settingsChangedDuringACleanAreKept() {
    let now = Date()
    var current = AppState()
    current.settings.keptFolders = ["/tmp/keep"]
    let merged = RunPolicy.merge(run: AppState(), current: current, now: now)
    #expect(merged.settings.keptFolders == ["/tmp/keep"])
  }

  // Always kept
  @Test func keptFolderIsRefusedQuietly() {
    let g = s.gateway(roots: ["Caches"], kept: ["Caches/keep"])
    s.file("Caches/keep/x")
    #expect(throws: DeletionGateway.Refusal.kept) { try g.delete(s.url("Caches/keep")) }
    #expect(throws: DeletionGateway.Refusal.kept) { try g.delete(s.url("Caches/keep/x")) }
    var result = CleanResult(category: .appCaches, bytesFreed: 0, errors: [])
    result.record(s.url("Caches/keep")) { try g.delete($0) }
    #expect(result.errors.isEmpty)
    #expect(s.exists("Caches/keep/x"))
  }

  @Test func aParentOfAKeptFolderIsKept() {
    let g = s.gateway(roots: ["Caches"], kept: ["Caches/tool/keep"])
    s.file("Caches/tool/keep/x")
    #expect(throws: DeletionGateway.Refusal.kept) { try g.delete(s.url("Caches/tool")) }
    #expect(s.exists("Caches/tool/keep/x"))
  }

  @Test func aSiblingOfAKeptFolderStillGoes() throws {
    let g = s.gateway(roots: ["Caches"], kept: ["Caches/keep"])
    s.file("Caches/keep/x")
    s.file("Caches/keeper/x")
    try g.delete(s.url("Caches/keeper"))
    #expect(!s.exists("Caches/keeper"))
  }

  @Test func aKeptFolderReachedThroughALinkIsStillKept() {
    s.file("Caches/real/x")
    s.link("Other", to: s.url("Caches/real"))
    let g = s.gateway(roots: ["Caches"], kept: ["Other"])
    #expect(throws: DeletionGateway.Refusal.kept) { try g.delete(s.url("Caches/real")) }
  }
}
