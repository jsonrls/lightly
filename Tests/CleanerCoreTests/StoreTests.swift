import Foundation
import Testing
@testable import CleanerCore

struct StoreTests {
  let box = Sandbox()
  var store: Store { Store(directory: box.url("state-dir")) }

  @Test func roundTrip() throws {
    var s = AppState()
    s.history = [RunRecord(date: Date(timeIntervalSince1970: 1_700_000_000), manual: true,
                           results: [CleanResult(category: .logs, bytesFreed: 5, errors: ["x"])])]
    s.inventory.installed = ["com.a"]
    s.diskSamples = [DiskSample(day: Date(timeIntervalSince1970: 1_700_000_000), freeBytes: 42)]
    s.paused = true
    s.lastScheduledRun = Date(timeIntervalSince1970: 1_700_000_100)
    s.lastWeeklyRun = Date(timeIntervalSince1970: 1_700_000_200)
    try store.save(s)
    #expect(store.load() == s)
  }

  @Test func missingFileGivesEmptyState() {
    #expect(store.load() == AppState())
  }

  @Test func corruptFileIsKeptAsideAndPauses() throws {
    box.dir("state-dir")
    try Data("{{{".utf8).write(to: box.url("state-dir/state.json"))
    let s = store.load()
    #expect(s.history.isEmpty && s.inventory == AppInventory())
    #expect(s.paused)
    #expect(try String(contentsOf: box.url("state-dir/state.corrupt.json"), encoding: .utf8) == "{{{")
    #expect(!box.exists("state-dir/state.json"))
  }

  @Test func peekPausesOnCorruptFileAndLeavesItInPlace() throws {
    box.dir("state-dir")
    try Data("{{{".utf8).write(to: box.url("state-dir/state.json"))
    let s = store.peek()
    #expect(s.paused)
    #expect(s.history.isEmpty && s.inventory == AppInventory())
    #expect(try String(contentsOf: box.url("state-dir/state.json"), encoding: .utf8) == "{{{")
    #expect(!box.exists("state-dir/state.corrupt.json"))
  }

  @Test func peekMatchesLoadOnGoodAndMissingFiles() throws {
    #expect(store.peek() == AppState())
    var s = AppState()
    s.lastScheduledRun = Date(timeIntervalSince1970: 1_700_000_100)
    try store.save(s)
    #expect(store.peek() == s)
    #expect(store.peek() == store.load())
  }

  @Test func secondCorruptionReplacesAside() throws {
    box.dir("state-dir")
    try Data("first".utf8).write(to: box.url("state-dir/state.json"))
    _ = store.load()
    try Data("second".utf8).write(to: box.url("state-dir/state.json"))
    #expect(store.load().paused)
    #expect(try String(contentsOf: box.url("state-dir/state.corrupt.json"), encoding: .utf8) == "second")
    #expect(!box.exists("state-dir/state.json"))
  }

  @Test func savedFileIsISO8601StateJSON() throws {
    var s = AppState()
    s.lastScheduledRun = Date(timeIntervalSince1970: 1_700_000_000)
    try store.save(s)
    let text = try String(contentsOf: box.url("state-dir/state.json"), encoding: .utf8)
    #expect(text.contains("\"2023-11-14T22:13:20Z\""))
  }

  @Test func saveFailureThrows() {
    box.file("blocker")  // a file where the directory should be
    #expect(throws: (any Error).self) { try Store(directory: box.url("blocker")).save(AppState()) }
  }

  @Test func pruneDropsOldEntries() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func rec(_ days: Double) -> RunRecord { RunRecord(date: now - days * Limits.day, manual: false, results: []) }
    var s = AppState()
    s.history = [rec(366), rec(364)]
    s.diskSamples = [DiskSample(day: now - 31 * Limits.day, freeBytes: 1),
                     DiskSample(day: now - 29 * Limits.day, freeBytes: 2)]
    s.prune(now: now)
    #expect(s.history.map(\.date) == [now - 364 * Limits.day])
    #expect(s.diskSamples.map(\.freeBytes) == [2])
  }

  @Test func defaultDirectoryPath() {
    let path = Store.defaultDirectory().path(percentEncoded: false)
    #expect(path.hasSuffix("/Library/Application Support/com.maccleaner.app/"))
  }
}
