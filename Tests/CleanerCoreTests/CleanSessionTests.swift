import Foundation
import Testing
@testable import CleanerCore

/// `DockerRule` candidates are real paths, so Docker tests need one to exist. `FakeRunner` still intercepts every call.
private let hasDockerBinary = DockerRule.defaultCandidates.contains {
  FileManager.default.isExecutableFile(atPath: $0.path(percentEncoded: false))
}

struct CleanSessionTests {
  let s = Sandbox()
  let now = Date()
  let runner = FakeRunner()

  @Test func aSwitchedOffCategoryIsNotRun() {
    fakeHome()
    var state = AppState()
    state.settings.disabled = [.logs]
    let record = CleanSession.run(env: env(), state: &state, now: now, manual: true).record
    #expect(s.exists("Library/Logs/old.log"))
    #expect(!record.results.contains { $0.category == .logs })
    #expect(!s.exists("Library/Caches/com.old.tool"))
  }

  @Test func anAlwaysKeptFolderSurvivesWithNoWarning() {
    fakeHome()
    var state = AppState()
    state.settings.keptFolders = [s.url("Library/Caches/com.old.tool").path(percentEncoded: false)]
    let record = CleanSession.run(env: env(), state: &state, now: now, manual: true).record
    #expect(s.exists("Library/Caches/com.old.tool"))
    #expect(!record.hasErrors)
  }

  static let allowed = [
    "Library/Caches", "Library/Logs", ".Trash", "Library/Application Support", "Library/Preferences",
    "Library/Saved Application State", "Library/HTTPStorages", "Library/WebKit",
    ".npm/_cacache", "Library/Caches/Yarn", "Library/pnpm/store", "Library/Caches/pip", "Library/Caches/Homebrew",
    "Library/Developer/Xcode/DerivedData",
  ]
  static let denied = [
    "Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music", "Library/Mail", "Library/Messages",
    "Library/Mobile Documents", "Library/Keychains", "Library/Safari", "Library/Containers", "Library/Group Containers",
    "Library/Application Support/Google/Chrome", "Library/Application Support/Firefox",
    "Library/Application Support/BraveSoftware", "Library/Application Support/Microsoft Edge",
    "Library/Application Support/Arc", "Library/Application Support/com.operasoftware.Opera",
    "Library/Application Support/com.operasoftware.OperaGX",
  ]
  /// What `fakeHome` plants for the rules to remove, one or more per category.
  static let removable = [
    "Library/Caches/com.old.tool", "Library/Caches/com.keep.app", "Library/Logs/old.log", ".Trash/old",
    ".npm/_cacache/x", "Library/Caches/Yarn/x", "Library/pnpm/store/x", "Library/Caches/pip/x",
    "Library/Caches/Homebrew/x", "Library/Developer/Xcode/DerivedData/Old-abc",
  ]
  static let leftoverCandidates = LeftoversTests.seven.map { "Library/" + $0 }
  static let leftoverData = "Library/Application Support/com.gone.app"

  /// A folder whose own date and content are both old, so idle checks really see it as idle.
  func oldFolder(_ path: String, ageDays: Double = 40) {
    s.file(path + "/data", ageDays: ageDays)
    s.dir(path, ageDays: ageDays)
  }

  func fakeHome() {
    s.dir("Applications/Keep.app/Contents")
    let plist = try! PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.keep.app"], format: .xml, options: 0)
    try! plist.write(to: s.url("Applications/Keep.app/Contents/Info.plist"))

    oldFolder("Library/Caches/com.old.tool")
    s.file("Library/Caches/com.keep.app/fresh")  // fresh: only the installed list can make it go
    s.file("Library/Logs/old.log", ageDays: 40)
    s.file(".Trash/old", ageDays: 40)
    for dir in [".npm/_cacache", "Library/Caches/Yarn", "Library/pnpm/store", "Library/Caches/pip", "Library/Caches/Homebrew"] {
      s.file(dir + "/x", ageDays: 40)
    }
    oldFolder("Library/Developer/Xcode/DerivedData/Old-abc")

    // Old files under the leftover roots that belong to no due app, so they must stay.
    oldFolder("Library/Application Support/com.other.app")
    s.file("Library/Preferences/com.other.app.plist", ageDays: 40)
    oldFolder("Library/Saved Application State/com.other.app.savedState")
    oldFolder("Library/HTTPStorages/com.other.app")
    oldFolder("Library/WebKit/com.other.app")

    for path in ["Documents/keep.txt", "Desktop/keep.txt", "Downloads/keep.txt",
                 "Library/Application Support/Google/Chrome/Cookies", "Library/Containers/com.x/data"] {
      s.file(path, ageDays: 40)
    }
  }

  func plantLeftover(ageDays: Double) {
    for path in Self.leftoverCandidates {
      if path.hasSuffix(".plist") { s.file(path, ageDays: ageDays) } else { oldFolder(path, ageDays: ageDays) }
    }
  }

  func dueState() -> AppState {
    var state = AppState()
    state.inventory.installed = ["com.gone.app", "com.keep.app"]
    state.inventory.removed["com.gone.app"] = now.addingTimeInterval(-31 * Limits.day)
    return state
  }

  func env(mode: DeletionGateway.Mode = .live, appExists: Bool = false, running: Set<String> = [],
           hooks: DeletionGateway.Hooks? = nil) -> CleanEnvironment {
    let added = now.addingTimeInterval(-40 * Limits.day)
    return CleanEnvironment(
      home: s.root, bootVolume: URL(filePath: "/"), appDirs: [s.url("Applications")],
      runningBundleIDs: { running }, appExistsAnywhere: { _ in appExists }, runner: runner,
      hooks: hooks ?? s.hooks, trashDateAdded: { _ in added }, mode: mode)
  }

  func npmrc(_ cache: String, at path: String = ".npmrc") throws {
    try "cache=\(cache)\n".write(to: s.url(path), atomically: true, encoding: .utf8)
  }

  func protectedTree() -> [String] {
    s.tree().filter { path in Self.denied.contains { path == $0 || path.hasPrefix($0 + "/") } }
  }

  func trashedCount() -> Int { s.tree().filter { $0.hasPrefix("__trash/") && !$0.dropFirst(8).contains("/") }.count }

  // MARK: Root lists

  @Test func rootListsAreExact() {
    func relative(_ urls: [URL]) -> Set<String> {
      Set(urls.map { $0.pathComponents.dropFirst(s.root.pathComponents.count).joined(separator: "/") })
    }
    #expect(relative(env().allowedRoots) == Set(Self.allowed))
    #expect(relative(env().deniedRoots) == Set(Self.denied))
  }

  @Test(arguments: ["ABSOLUTE", "~/../home-other"])
  func npmCacheOutsideHomeIsNotAllowed(_ cache: String) throws {
    s.dir("home")
    s.file("home-other/_cacache/x")  // shares a string prefix with home
    try npmrc(cache == "ABSOLUTE" ? s.url("home-other").path(percentEncoded: false) : cache, at: "home/.npmrc")
    var e = env()
    e.home = s.url("home")
    var state = AppState()
    let (_, touched) = CleanSession.run(env: e, state: &state, now: now, manual: true)
    #expect(s.exists("home-other/_cacache/x"))
    #expect(touched.isEmpty)
    #expect(e.allowedRoots.count == Self.allowed.count - 1)
  }

  // MARK: Weekly rules

  @Test func dailyRunSkipsWeekly() {
    fakeHome()
    var state = AppState()
    let lastWeekly = now.addingTimeInterval(-Limits.day)
    state.lastWeeklyRun = lastWeekly
    let (record, _) = CleanSession.run(env: env(), state: &state, now: now, manual: false)
    #expect(s.exists(".npm/_cacache/x"))
    #expect(s.exists("Library/Developer/Xcode/DerivedData/Old-abc"))
    #expect(Set(record.results.map(\.category)) == [.appCaches, .logs, .trash, .leftovers])
    #expect(!s.exists("Library/Logs/old.log"))  // the daily rules did run
    #expect(state.lastWeeklyRun == lastWeekly)
    #expect(runner.calls.isEmpty)
  }

  @Test func scheduledRunIncludesWeeklyWhenDue() {
    fakeHome()
    var state = AppState()
    state.lastWeeklyRun = now.addingTimeInterval(-8 * Limits.day)
    let (record, _) = CleanSession.run(env: env(), state: &state, now: now, manual: false)
    #expect(!s.exists(".npm/_cacache/x"))
    #expect(Set(record.results.map(\.category)) == Set(CleanCategory.allCases))
    #expect(state.lastWeeklyRun == now)
  }

  @Test func manualRunIncludesWeekly() {
    fakeHome()
    plantLeftover(ageDays: 40)
    var state = dueState()
    state.lastWeeklyRun = now.addingTimeInterval(-Limits.day)
    let (record, _) = CleanSession.run(env: env(), state: &state, now: now, manual: true)
    for path in Self.removable + Self.leftoverCandidates { #expect(!s.exists(path), "\(path)") }
    #expect(s.exists(".npm/_cacache"))
    #expect(!record.hasErrors)
    #expect(Set(record.results.map(\.category)) == Set(CleanCategory.allCases))
    for result in record.results where result.category != .docker { #expect(result.bytesFreed > 0, "\(result.category)") }
    #expect(state.lastWeeklyRun == now)
  }

  // MARK: Protection

  // A custom npm cache is the one input that can steer a rule into a denied root, so each root is tried that way.
  @Test(arguments: denied)
  func protectedFoldersUntouched(_ root: String) throws {
    fakeHome()
    try npmrc("~/\(root)")
    s.file(root + "/_cacache/x", ageDays: 40)
    let before = protectedTree()
    var state = AppState()
    let (record, _) = CleanSession.run(env: env(), state: &state, now: now, manual: true)
    #expect(protectedTree() == before)
    #expect(before.contains(root + "/_cacache/x"))
    // The rule did try: the gateway stopped it, not a missing fixture.
    #expect(record.results.first { $0.category == .devCaches }?.errors.count == 1)
  }

  @Test func everyTouchedPathIsUnderAnAllowedRoot() {
    fakeHome()
    plantLeftover(ageDays: 40)
    var state = dueState()
    let e = env()
    let (_, touched) = CleanSession.run(env: e, state: &state, now: now, manual: true)
    #expect(touched.count >= Self.removable.count + Self.leftoverCandidates.count)
    for url in touched {
      let inside = e.allowedRoots.contains {
        url.pathComponents.count > $0.pathComponents.count && url.pathComponents.starts(with: $0.pathComponents)
      }
      #expect(inside, "\(url.path(percentEncoded: false))")
    }
  }

  @Test func dryRunChangesNothing() {
    fakeHome()
    plantLeftover(ageDays: 40)
    let before = s.tree()
    var state = dueState()
    let original = state
    let (record, touched) = CleanSession.run(env: env(mode: .dryRun), state: &state, now: now, manual: true)
    #expect(s.tree() == before)
    #expect(state == original)
    #expect(!touched.isEmpty)
    #expect(record.totalBytes > 0)
  }

  @Test func otherVolumeMeansNoDeletion() {
    fakeHome()
    plantLeftover(ageDays: 40)
    let before = s.tree()
    var hooks = s.hooks
    hooks.volumeOf = { _ in URL(filePath: "/Volumes/json SSD") }
    var state = dueState()
    let (record, touched) = CleanSession.run(env: env(hooks: hooks), state: &state, now: now, manual: true)
    #expect(touched.isEmpty)
    #expect(s.tree() == before)
    #expect(!record.hasErrors)
    #expect(state.inventory.removed["com.gone.app"] != nil)  // nothing went, so it is not marked cleaned
    #expect(!runner.calls.contains { $0.contains("prune") })
  }

  // MARK: Leftovers

  @Test func leftoverFlow() {
    fakeHome()
    plantLeftover(ageDays: 40)
    var state = dueState()
    let (record, _) = CleanSession.run(env: env(), state: &state, now: now, manual: false)
    #expect(!record.hasErrors)
    for path in Self.leftoverCandidates { #expect(!s.exists(path), "\(path)") }
    // All seven in the Trash: a cache rule running first would delete some for good.
    #expect(trashedCount() == 7)
    #expect(state.inventory.removed["com.gone.app"] == nil)
    #expect(!state.inventory.installed.contains("com.gone.app"))
  }

  @Test func leftoverSparedWhenAppStillExists() {
    fakeHome()
    plantLeftover(ageDays: 40)
    var state = dueState()
    _ = CleanSession.run(env: env(appExists: true), state: &state, now: now, manual: false)
    #expect(s.exists(Self.leftoverData))
    #expect(trashedCount() == 0)
    #expect(state.inventory.removed["com.gone.app"] == now)
  }

  @Test func leftoverSparedWhenDataIsFresh() {
    fakeHome()
    plantLeftover(ageDays: 5)
    var state = dueState()
    _ = CleanSession.run(env: env(), state: &state, now: now, manual: false)
    #expect(s.exists(Self.leftoverData))
    #expect(trashedCount() == 0)
    #expect(state.inventory.removed["com.gone.app"] == now)
  }

  @Test func browserDataResetsClockAndTrashesNothing() {
    fakeHome()
    plantLeftover(ageDays: 40)
    s.file(Self.leftoverData + "/Default/Login Data", ageDays: 40)
    var state = dueState()
    _ = CleanSession.run(env: env(), state: &state, now: now, manual: false)
    #expect(s.exists(Self.leftoverData + "/Default/Login Data"))
    #expect(trashedCount() == 0)
    #expect(state.inventory.removed["com.gone.app"] == now)
  }

  @Test func failedTrashIsRetried() {
    fakeHome()
    oldFolder(Self.leftoverData)
    oldFolder("Library/Logs/com.gone.app")  // the log rule empties it after the failed trash, refreshing the folder date
    var failing = s.hooks
    failing.trash = { _ in throw CocoaError(.fileWriteNoPermission) }
    var state = dueState()
    let firstSeen = state.inventory.removed["com.gone.app"]
    let (record, _) = CleanSession.run(env: env(hooks: failing), state: &state, now: now, manual: false)
    #expect(record.results.first { $0.category == .leftovers }?.errors.count == 2)
    #expect(s.exists(Self.leftoverData))
    #expect(!s.exists("Library/Logs/com.gone.app/data"))
    #expect(state.inventory.removed["com.gone.app"] == firstSeen)
    #expect(state.inventory.installed.contains("com.gone.app"))

    let later = now.addingTimeInterval(Limits.day)
    _ = CleanSession.run(env: env(), state: &state, now: later, manual: false)
    #expect(!s.exists(Self.leftoverData))
    #expect(!s.exists("Library/Logs/com.gone.app"))
    #expect(state.inventory.removed["com.gone.app"] == nil)
  }

  @Test func logCleanupDoesNotResetClock() {
    fakeHome()
    plantLeftover(ageDays: 40)
    var state = dueState()
    state.inventory.removed["com.gone.app"] = now.addingTimeInterval(-29 * Limits.day)
    // Still in the grace period: the log rule empties Logs/<id>, which refreshes the folder date.
    _ = CleanSession.run(env: env(), state: &state, now: now, manual: false)
    #expect(s.exists("Library/Logs/com.gone.app") && !s.exists("Library/Logs/com.gone.app/data"))

    _ = CleanSession.run(env: env(), state: &state, now: now.addingTimeInterval(2 * Limits.day), manual: false)
    #expect(!s.exists(Self.leftoverData))
    #expect(state.inventory.removed["com.gone.app"] == nil)
  }

  // MARK: Wiring

  @Test func cacheRuleSeesUpdatedInventoryAndRunningApps() {
    fakeHome()
    var state = AppState()  // com.keep.app is learned from this run's scan
    _ = CleanSession.run(env: env(), state: &state, now: now, manual: false)
    #expect(!s.exists("Library/Caches/com.keep.app"))
    #expect(state.inventory.installed == ["com.keep.app"])

    s.file("Library/Caches/com.keep.app/fresh")
    _ = CleanSession.run(env: env(running: ["com.keep.app"]), state: &state, now: now, manual: false)
    #expect(s.exists("Library/Caches/com.keep.app"))
  }

  @Test func stampsAndHistory() {
    fakeHome()
    var state = AppState()
    let (record, _) = CleanSession.run(env: env(), state: &state, now: now, manual: false)
    #expect(state.lastScheduledRun == now)
    #expect(state.history == [record])

    let earlier = now
    let later = now.addingTimeInterval(60)
    let (manual, _) = CleanSession.run(env: env(), state: &state, now: later, manual: true)
    #expect(state.lastScheduledRun == earlier)
    #expect(state.history == [record, manual])
    #expect(manual.manual && !record.manual)
  }

  @Test func oldHistoryIsPruned() {
    fakeHome()
    var state = AppState()
    state.history = [RunRecord(date: now.addingTimeInterval(-366 * Limits.day), manual: false, results: [])]
    let (record, _) = CleanSession.run(env: env(), state: &state, now: now, manual: false)
    #expect(state.history == [record])
  }

  // MARK: Docker (FakeRunner only; no real Docker runs)

  static let prunes = [["info"], ["builder", "prune", "-f"], ["image", "prune", "-f"]]

  func dockerSettings(dataFolder: URL) throws {
    let dir = s.dir("Library/Group Containers/group.com.docker")
    let json = try JSONSerialization.data(withJSONObject: ["DataFolder": dataFolder.path(percentEncoded: false)])
    try json.write(to: dir.appending(path: "settings-store.json"))
  }

  func dockerCalls(hooks: DeletionGateway.Hooks? = nil, mode: DeletionGateway.Mode = .live) -> [[String]] {
    var state = AppState()
    _ = CleanSession.run(env: env(mode: mode, hooks: hooks), state: &state, now: now, manual: true)
    return runner.calls
  }

  @Test(.enabled(if: hasDockerBinary)) func dockerPrunesInLiveMode() { #expect(dockerCalls() == Self.prunes) }

  @Test(.enabled(if: hasDockerBinary)) func dockerFollowsDryRun() { #expect(dockerCalls(mode: .dryRun) == [["info"]]) }

  @Test(.enabled(if: hasDockerBinary)) func dockerDataFolderOnBootVolumePrunes() throws {
    try dockerSettings(dataFolder: s.dir("docker-data"))
    #expect(dockerCalls() == Self.prunes)
  }

  @Test(.enabled(if: hasDockerBinary)) func dockerDataFolderOnOtherVolumeSkips() throws {
    try dockerSettings(dataFolder: s.dir("docker-data"))
    var hooks = s.hooks
    hooks.volumeOf = { url in
      URL(filePath: url.path(percentEncoded: false).contains("docker-data") ? "/Volumes/json SSD" : "/")
    }
    #expect(dockerCalls(hooks: hooks) == [["info"]])
  }

  @Test(.enabled(if: hasDockerBinary)) func dockerDataFolderThatDoesNotResolveSkips() throws {
    try dockerSettings(dataFolder: s.url("missing"))  // s.hooks says "/" for any path, so only the resolve check can stop it
    #expect(dockerCalls() == [["info"]])
  }
}
