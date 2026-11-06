# Mac Cleaner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A native macOS menu bar app that cleans caches, logs, Trash, app leftovers and developer caches by itself, and shows disk, memory, CPU and battery.

**Architecture:** One Swift package. `CleanerCore` (library) holds every rule and the single deletion gateway, with no UI, fully unit-tested against temporary folders. `MacCleaner` (executable) is a thin SwiftUI layer. A shell script wraps the release binary into an `.app` bundle; there is no Xcode project file.

**Tech Stack:** Swift 6, SwiftUI (`MenuBarExtra`), Swift Charts, Swift Testing, SwiftPM. No third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-11-06-mac-cleaner-design.md`

## Global Constraints

- Deletion happens only through `DeletionGateway`. No other code calls `FileManager.removeItem` or `trashItem`.
- The app touches only the internal volume that holds the home folder. Never an external volume, including `/Volumes/json SSD`.
- No test reads or writes a real user folder. Tests use a temporary directory only.
- Debug builds are dry-run only. Release builds are live unless `MACCLEANER_DRY_RUN=1`.
- No admin rights, no sandbox, hardened runtime on, no third-party dependencies.
- Deployment target macOS 27.0. Do not lower it without asking the owner.
- Age limits, exact: logs 7 days, Trash 30 days, leftovers 30 days, unmatched cache idle 7 days, DerivedData idle 7 days, developer caches every 7 days, daily run at 03:00 local.
- Bundle identifier `com.maccleaner.app`. Display name "Mac Cleaner".
- Git: work on `feature/mac-cleaner-v1` off `staging`. Local commits are part of each task. Nothing is pushed and no GitHub repo is created without the owner's OK (Task 11).
- Verify SwiftUI, ServiceManagement and Swift Charts API names against current Apple documentation (Context7) before using them.

## Review Focus

1. `/Applications` unreadable or scan returns nothing: no app is marked removed. (Task 4)
2. A cache folder, or one of its parents, is a symlink to another place or volume: nothing is deleted. (Task 2)
3. Trash unreadable because Full Disk Access is missing: Trash is skipped, every other category still runs, no error mark. (Task 3)
4. A file is locked or vanishes mid-run: that item is recorded as an error and the run continues. (Task 3)
5. State file missing or corrupt: the app starts with empty state, cleans nothing at once, and never reads "empty inventory" as "all apps removed". (Task 6)

## File Structure

```
Package.swift
Sources/CleanerCore/
  Model.swift            CleanCategory, CleanResult, RunRecord, Limits, CleanRule
  DeletionGateway.swift  the only path to deletion
  FileRules.swift        CacheRule, LogRule, TrashRule
  Leftovers.swift        AppInventory, InstalledApps, LeftoverRule
  DevCaches.swift        DevCacheRule
  Docker.swift           CommandRunner, ProcessRunner, DockerRule
  Store.swift            AppState, DiskSample, Store
  Scheduler.swift        when to run
  CleanSession.swift     CleanEnvironment, CleanSession.run
  SystemStats.swift      StatsSnapshot, SystemStats
  Format.swift           text shown in the UI
Sources/MacCleaner/
  MacCleanerApp.swift  AppModel.swift  PopoverView.swift  StatTile.swift  FullView.swift
Tests/CleanerCoreTests/  Sandbox.swift plus one test file per source file
Resources/Info.plist
scripts/bundle.sh
.github/workflows/ci.yml
```

---

### Task 1: Repository and package skeleton

**Files:** Create `.gitignore`, `Package.swift`, `Sources/CleanerCore/Model.swift`, `Sources/MacCleaner/MacCleanerApp.swift`, `Tests/CleanerCoreTests/ModelTests.swift`, `.github/workflows/ci.yml`

**Produces:** package `MacCleaner` with targets `CleanerCore`, `MacCleaner`, `CleanerCoreTests`.

- [ ] **Step 1:** `git init -b main`. Write `.gitignore` with `.build/`, `dist/`, `.superpowers/`, `.DS_Store`. Commit `.gitignore` and `docs/` as the root commit, then `git switch -c staging` and `git switch -c feature/mac-cleaner-v1`.
- [ ] **Step 2:** Write `Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
  name: "MacCleaner",
  platforms: [.macOS("27.0")],
  targets: [
    .target(name: "CleanerCore"),
    .executableTarget(name: "MacCleaner", dependencies: ["CleanerCore"]),
    .testTarget(name: "CleanerCoreTests", dependencies: ["CleanerCore"]),
  ]
)
```

- [ ] **Step 3:** Write the failing test in `ModelTests.swift`:

```swift
@Test func categoryNames() {
  #expect(CleanCategory.allCases.map(\.displayName) ==
    ["App caches", "Logs", "Trash (30+ days)", "App leftovers", "Developer caches", "Docker build cache"])
}
@Test func recordTotals() {
  let r = RunRecord(date: .now, manual: false, results: [
    CleanResult(category: .logs, bytesFreed: 10, errors: []),
    CleanResult(category: .trash, bytesFreed: 5, errors: ["x"])])
  #expect(r.totalBytes == 15); #expect(r.hasErrors)
}
```

- [ ] **Step 4:** Run `swift test`. Expected: FAIL, `CleanCategory` not found.
- [ ] **Step 5:** Implement in `Model.swift`:

```swift
public enum CleanCategory: String, Codable, CaseIterable, Sendable {
  case appCaches, logs, trash, leftovers, devCaches, docker
  public var displayName: String
}
public struct CleanResult: Codable, Sendable, Equatable {
  public var category: CleanCategory; public var bytesFreed: Int64; public var errors: [String]
}
public struct RunRecord: Codable, Sendable, Equatable {
  public var date: Date; public var manual: Bool; public var results: [CleanResult]
  public var totalBytes: Int64 { get }; public var hasErrors: Bool { get }
}
public enum Limits {
  public static let day: TimeInterval = 86_400
  public static let logAge = 7 * day, trashAge = 30 * day, leftoverGrace = 30 * day
  public static let cacheIdle = 7 * day, derivedDataIdle = 7 * day, weekly = 7 * day
  public static let runHour = 3
}
public protocol CleanRule: Sendable {
  var category: CleanCategory { get }
  var weekly: Bool { get }
  func run(gateway: DeletionGateway, now: Date) -> CleanResult
}
```

`MacCleanerApp.swift` is a stub `@main` App with an empty `MenuBarExtra` for now. `CleanRule` compiles once Task 2 adds the gateway; until then keep it commented.

- [ ] **Step 6:** Write `ci.yml`: on `push` and `pull_request`, one job on `macos-latest` running `swift build` then `swift test`. If that runner's toolchain cannot build for macOS 27, pin the newest `macos-NN` label that can; do not lower the deployment target.
- [ ] **Step 7:** Run `swift test`. Expected: PASS. Commit: `chore: package skeleton, model types, CI`.

---

### Task 2: DeletionGateway

**Files:** Create `Sources/CleanerCore/DeletionGateway.swift`, `Tests/CleanerCoreTests/Sandbox.swift`, `Tests/CleanerCoreTests/DeletionGatewayTests.swift`. Modify `Model.swift` (enable `CleanRule`, add `CleanResult.record`).

**Produces:**

```swift
public final class DeletionGateway: @unchecked Sendable {
  public enum Mode: Sendable { case live, dryRun }
  public enum Refusal: Error, Equatable { case symlink, outsideAllowedRoots, denied, notOnBootVolume }
  public struct Hooks: Sendable {
    public var volumeOf: @Sendable (URL) -> URL?      // nil = unknown or not internal
    public var remove: @Sendable (URL) throws -> Void
    public var trash: @Sendable (URL) throws -> Void
    public static let live: Hooks
  }
  public init(allowedRoots: [URL], deniedRoots: [URL], bootVolume: URL, mode: Mode, hooks: Hooks = .live)
  public func validate(_ url: URL) throws
  @discardableResult public func delete(_ url: URL) throws -> Int64   // bytes freed
  @discardableResult public func trash(_ url: URL) throws -> Int64
  public var touched: [URL] { get }   // deleted, trashed, or would-be in dry run
}
extension CleanResult {
  /// Runs `op`. `.symlink` and `.notOnBootVolume` are silent skips; any other error is appended as "<name>: <message>".
  public mutating func record(_ url: URL, _ op: (URL) throws -> Int64)
}
```

`validate` checks in this order: the URL itself is a symlink → `.symlink`; resolve symlinks in the path, then it must be strictly inside an allowed root (never the root itself) → `.outsideAllowedRoots`; inside or equal to a denied root → `.denied`; `hooks.volumeOf(resolved) != bootVolume` → `.notOnBootVolume`. On every call, an allowed root whose own URL is a symlink is ignored (so `refusesSymlinkedRoot` gets `.outsideAllowedRoots`, even when the link appeared after the gateway was built); the remaining roots, and all denied roots, are resolved the same way before comparing. `Hooks.live.volumeOf` returns `volumeURLKey` only when `volumeIsInternalKey` is true. Size is the sum of `totalFileAllocatedSizeKey` without following links. In `.dryRun` nothing is removed; size and `touched` are still reported.

Test helper, used by every later task:

```swift
struct Sandbox {
  let root: URL   // fresh temp dir, symlinks resolved
  @discardableResult func file(_ path: String, bytes: Int = 1024, ageDays: Double = 0) -> URL
  @discardableResult func dir(_ path: String, ageDays: Double = 0) -> URL
  @discardableResult func link(_ path: String, to target: URL) -> URL
  func url(_ path: String) -> URL
  func exists(_ path: String) -> Bool
  func tree() -> [String]   // sorted relative paths under root
  var hooks: DeletionGateway.Hooks   // volumeOf: constant URL(filePath: "/"); trash: moves into root/__trash, appending " 2", " 3"… on a name collision
  func gateway(roots: [String], denied: [String] = [], mode: DeletionGateway.Mode = .live,
               hooks: DeletionGateway.Hooks? = nil) -> DeletionGateway   // bootVolume "/"
}
```

- [ ] **Step 1: Write the failing tests** (`s` is a fresh `Sandbox`, `g = s.gateway(roots: ["Caches"])` unless shown):

```swift
@Test func deletesInsideRoot() throws { let f = s.file("Caches/a/x"); #expect(try g.delete(f) > 0); #expect(!s.exists("Caches/a/x")) }
@Test func refusesOutsideRoots() { let f = s.file("Documents/x"); #expect(throws: Refusal.outsideAllowedRoots) { try g.delete(f) }; #expect(s.exists("Documents/x")) }
@Test func refusesRootItself() { s.dir("Caches"); #expect(throws: Refusal.outsideAllowedRoots) { try g.delete(s.url("Caches")) } }
@Test func refusesDenied() { let g = s.gateway(roots: ["Lib"], denied: ["Lib/Mail"]); let f = s.file("Lib/Mail/x"); #expect(throws: Refusal.denied) { try g.delete(f) } }
@Test func refusesSymlinkTarget() { let t = s.file("Documents/real"); let l = s.link("Caches/l", to: t); #expect(throws: Refusal.symlink) { try g.delete(l) }; #expect(s.exists("Documents/real")) }
@Test func refusesThroughSymlinkedParent() { s.file("Elsewhere/x"); s.link("Caches/d", to: s.url("Elsewhere")); #expect(throws: Refusal.outsideAllowedRoots) { try g.delete(s.url("Caches/d/x")) }; #expect(s.exists("Elsewhere/x")) }
@Test func refusesSymlinkedRoot() { s.file("Elsewhere/x"); s.link("Caches", to: s.url("Elsewhere")); #expect(throws: (any Error).self) { try g.delete(s.url("Caches/x")) }; #expect(s.exists("Elsewhere/x")) }
@Test func refusesOtherVolume() { var h = s.hooks; h.volumeOf = { _ in URL(filePath: "/Volumes/json SSD") }; let g = s.gateway(roots: ["Caches"], hooks: h); let f = s.file("Caches/x"); #expect(throws: Refusal.notOnBootVolume) { try g.delete(f) }; #expect(s.exists("Caches/x")) }
@Test func refusesUnknownVolume() { /* volumeOf returns nil → .notOnBootVolume */ }
@Test func dryRunKeepsFile() throws { let g = s.gateway(roots: ["Caches"], mode: .dryRun); let f = s.file("Caches/x", bytes: 4096); #expect(try g.delete(f) >= 4096); #expect(s.exists("Caches/x")); #expect(g.touched == [f]) }
@Test func nestedLinkTargetSurvives() throws { let t = s.file("Documents/real"); s.link("Caches/a/l", to: t); try g.delete(s.url("Caches/a")); #expect(s.exists("Documents/real")) }
@Test func trashUsesTrashHook() throws { let f = s.file("Caches/x"); try g.trash(f); #expect(s.exists("__trash/x")) }
@Test func recordSkipsSilently() { /* record() on a symlink leaves errors empty; on .denied appends one error */ }
```

- [ ] **Step 2:** Run `swift test --filter DeletionGatewayTests`. Expected: FAIL to compile.
- [ ] **Step 3:** Implement `DeletionGateway`, `Sandbox` and `CleanResult.record` as specified above.
- [ ] **Step 4:** Run `swift test --filter DeletionGatewayTests`. Expected: PASS.
- [ ] **Step 5:** Commit: `feat: deletion gateway`.

---

### Task 3: Cache, log and Trash rules

**Files:** Create `Sources/CleanerCore/FileRules.swift`, `Tests/CleanerCoreTests/FileRulesTests.swift`

**Consumes:** `DeletionGateway`, `CleanResult.record`, `Limits`, `Sandbox`.

**Produces:**

```swift
public struct CacheRule: CleanRule {   // category .appCaches, weekly false
  public init(cachesDir: URL, runningBundleIDs: @escaping @Sendable () -> Set<String>, installedBundleIDs: Set<String>)
  public static let skipExact: Set<String>   // CloudKit, GeoServices, PassKit, FamilyCircle, SiriEntityCache, GameKit, Animoji, Cypress, electron, puppeteer, org.webkit.Playwright, Homebrew, pip, Yarn
  public static let skipPrefixes: [String]   // "com.apple.", "ms-playwright"
}
public struct LogRule: CleanRule { public init(logsDir: URL) }   // .logs
public struct TrashRule: CleanRule {                              // .trash
  public init(trashDir: URL, dateAdded: @escaping @Sendable (URL) -> Date? = TrashRule.systemDateAdded)
  public static let systemDateAdded: @Sendable (URL) -> Date?   // addedToDirectoryDateKey
  public static func hasAccess(trashDir: URL) -> Bool
}
func newestModification(in url: URL) -> Date   // the folder and everything under it, links not followed
```

`CacheRule` per top-level entry of `cachesDir`: skip if on a skip list; skip if the name equals a running bundle ID or starts with one plus "."; delete if the name is in `installedBundleIDs`; otherwise delete only when `now - newestModification >= Limits.cacheIdle`. `Homebrew`, `pip` and `Yarn` are skipped here because `DevCacheRule` owns them. `LogRule` deletes regular files with modification date at least 7 days old, at any depth, and keeps directories. `TrashRule` deletes top-level items whose `dateAdded` is at least 30 days old; a `nil` date means keep. An unreadable `trashDir` returns an empty result with no errors.

- [ ] **Step 1: Write the failing tests** (gateway roots `["Caches", "Logs", "Trash"]`, `now = Date()`):

```swift
// CacheRule(running: ["com.foo.app"], installed: ["com.foo.app", "com.bar.app"])
@Test func skipsRunningAppAndItsHelpers()   // Caches/com.foo.app and Caches/com.foo.app.helper exist after
@Test func deletesInstalledIdleApp()        // Caches/com.bar.app gone, bytesFreed > 0
@Test func skipsAppleAndSkipList()          // com.apple.Safari, CloudKit, ms-playwright, ms-playwright-go, Cypress, Homebrew all exist after, each aged 30 days
@Test func unmatchedNeedsSevenIdleDays()    // "SomeTool" file aged 8 days → gone; "OtherTool" aged 6 days → exists
@Test func continuesAfterFailure()          // hooks.remove throws for "com.bar.app" only: errors.count == 1 and "SomeTool" (aged 8) is gone
@Test func symlinkEntryIsSilent()           // Caches/l → Documents: errors.isEmpty, Documents intact
// LogRule
@Test func oldLogDeletedFreshKept()         // Logs/a/old.log aged 8 → gone; Logs/a/new.log aged 6 → exists; Logs/a exists
// TrashRule with injected dateAdded
@Test func trashThirtyDayBoundary()         // added 30 days ago → gone; 29 days → exists; nil → exists
@Test func unreadableTrashIsQuiet()         // trashDir does not exist: result.bytesFreed == 0, errors.isEmpty, hasAccess == false
```

- [ ] **Step 2:** Run `swift test --filter FileRulesTests`. Expected: FAIL to compile.
- [ ] **Step 3:** Implement the three rules and `newestModification` as specified.
- [ ] **Step 4:** Run `swift test --filter FileRulesTests`. Expected: PASS.
- [ ] **Step 5:** Commit: `feat: cache, log and Trash rules`.

---

### Task 4: App inventory and leftovers

**Files:** Create `Sources/CleanerCore/Leftovers.swift`, `Tests/CleanerCoreTests/LeftoversTests.swift`

**Produces:**

```swift
public struct AppInventory: Codable, Sendable, Equatable {
  public var installed: Set<String> = []
  public var removed: [String: Date] = [:]            // bundle ID → date first seen missing
  public init()
  public mutating func update(present: Set<String>, now: Date)   // no-op when present is empty
  public func due(now: Date) -> [String]              // missing ≥ 30 days, never com.apple.*
  public mutating func resetClock(_ id: String, now: Date)
  public mutating func markCleaned(_ ids: [String])   // drop from removed
}
public enum InstalledApps { public static func scan(_ dirs: [URL]) -> Set<String> }   // *.app at depth 1 and 2, CFBundleIdentifier from Contents/Info.plist
public struct LeftoverRule: CleanRule {   // .leftovers, weekly false, uses gateway.trash
  public init(libraryDir: URL, bundleIDs: [String])
  public static func candidates(libraryDir: URL, bundleID: String) -> [URL]
  public static func recentlyUsed(libraryDir: URL, bundleID: String, now: Date) -> Bool   // any candidate modified within 30 days
}
```

`update`: an ID in `installed` but not in `present` gets `removed[id] = now` unless already set; an ID in `present` is added to `installed` and dropped from `removed`. `candidates` returns, under `libraryDir`: `Application Support/<id>`, `Caches/<id>`, `Preferences/<id>.plist`, `Saved Application State/<id>.savedState`, `HTTPStorages/<id>`, `WebKit/<id>`, `Logs/<id>`; it returns `[]` for an ID that does not match `^[A-Za-z0-9.-]+$` or contains `..`.

- [ ] **Step 1: Write the failing tests:**

```swift
@Test func firstScanMarksNothingRemoved()   // empty inventory, update(["a.b"]) → removed.isEmpty
@Test func disappearanceIsDated()           // then update(["x.y"], now: t) → removed["a.b"] == t; a second update keeps t
@Test func returningAppResetsClock()        // update(["a.b"]) again → removed["a.b"] == nil
@Test func emptyScanChangesNothing()        // update([], now) leaves the inventory equal to before
@Test func dueAtThirtyDays()                // removed 29 days ago → not due; 30 days → due
@Test func appleNeverDue()                  // removed["com.apple.Foo"] 90 days ago → due(now) is empty
@Test func scanReadsBundleIDs()             // Apps/Foo.app and Apps/Utilities/Bar.app fixtures → both IDs; a folder without Info.plist ignored
@Test func trashesOnlyTheSevenCandidates()  // all seven paths for "com.gone.app" are gone from Library and __trash holds seven entries; Application Support/com.other.app and Containers/com.gone.app still exist
@Test func hostileIDsYieldNothing()         // candidates(bundleID: "../../Documents") and "a/b" → []
@Test func recentlyUsedDetectsFreshData()   // candidate modified 5 days ago → true; 40 days → false
```

- [ ] **Step 2:** Run `swift test --filter LeftoversTests`. Expected: FAIL to compile.
- [ ] **Step 3:** Implement as specified.
- [ ] **Step 4:** Run `swift test --filter LeftoversTests`. Expected: PASS.
- [ ] **Step 5:** Commit: `feat: app inventory and leftover rule`.

---

### Task 5: Developer caches and Docker

**Files:** Create `Sources/CleanerCore/DevCaches.swift`, `Sources/CleanerCore/Docker.swift`, `Tests/CleanerCoreTests/DevCachesTests.swift`, `Tests/CleanerCoreTests/DockerTests.swift`

**Produces:**

```swift
public struct DevCacheRule: CleanRule {   // .devCaches, weekly true
  public init(home: URL, environment: [String: String] = ProcessInfo.processInfo.environment)
  public static func wholeCacheDirs(home: URL, environment: [String: String]) -> [URL]
  public static func derivedDataDir(home: URL) -> URL   // Library/Developer/Xcode/DerivedData
}
public protocol CommandRunner: Sendable {
  func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) -> (status: Int32, output: String)?   // nil on launch failure or timeout
}
public struct ProcessRunner: CommandRunner { public init() }
public struct DockerRule: CleanRule {     // .docker, weekly true; does not use the gateway
  public init(home: URL, runner: any CommandRunner, mode: DeletionGateway.Mode,
              isOnBootVolume: @escaping @Sendable (URL) -> Bool,
              candidates: [URL] = DockerRule.defaultCandidates)
  public static let defaultCandidates: [URL]   // /usr/local/bin/docker, /opt/homebrew/bin/docker, /Applications/Docker.app/Contents/Resources/bin/docker
  public static func parseReclaimed(_ output: String) -> Int64
}
```

`wholeCacheDirs`: npm `<cache>/_cacache` where `<cache>` is `environment["npm_config_cache"]`, else the `cache=` line of `~/.npmrc`, else `~/.npm`; then `Library/Caches/Yarn`, `Library/pnpm/store`, `Library/Caches/pip`, `Library/Caches/Homebrew`. The rule deletes the children of each directory, never the directory. In DerivedData it deletes only project folders whose `newestModification` is at least 7 days old. A missing directory is not an error.

`DockerRule.run`: first existing candidate, else return empty. `docker info` with a 10 s timeout must exit 0, else return empty; never launch Docker. Read Docker Desktop's settings file under `~/Library/Group Containers/group.com.docker/` (check `settings-store.json` then `settings.json`, key `DataFolder` or `dataFolder`; confirm the key against the real file on this Mac, read-only); if the data folder is set and `isOnBootVolume` is false, return empty. In `.dryRun` stop here. Then run exactly `builder prune -f` and `image prune -f` with a 120 s timeout each and sum `parseReclaimed`. A non-zero exit is an error string. `parseReclaimed` reads the number after `Total reclaimed space:` with decimal units B, kB, MB, GB, TB.

- [ ] **Step 1: Write the failing tests:**

```swift
@Test func clearsChildrenKeepsDirs()        // files under .npm/_cacache, Library/Caches/pip, Library/Caches/Homebrew, Library/Caches/Yarn, Library/pnpm/store gone; the five dirs exist
@Test func missingToolIsNotAnError()        // empty home → errors.isEmpty
@Test func npmrcCacheHonoured()             // .npmrc "cache=<root>/custom" → wholeCacheDirs contains custom/_cacache
@Test func envBeatsNpmrc()                  // npm_config_cache set → that path wins
@Test func derivedDataSevenDayBoundary()    // DerivedData/Old-abc aged 8 → gone; DerivedData/New-def aged 6 → exists
// DockerRule with a FakeRunner recording calls
@Test func noBinaryRunsNothing()
@Test func stoppedDaemonRunsNoPrune()       // info exits 1 → calls == [["info"]]
@Test func runsExactlyTwoPrunes()           // calls == [["info"], ["builder","prune","-f"], ["image","prune","-f"]]
@Test func neverTouchesVolumesOrTaggedImages() // no call contains "volume", "system", "container" or "-a"
@Test func externalDataFolderSkips()        // settings file points off the boot volume → calls == [["info"]]
@Test func dryRunStopsAfterInfo()
@Test func parsesReclaimed() {
  #expect(DockerRule.parseReclaimed("Total reclaimed space: 1.2GB") == 1_200_000_000)
  #expect(DockerRule.parseReclaimed("Total reclaimed space: 310MB") == 310_000_000)
  #expect(DockerRule.parseReclaimed("Total reclaimed space: 52.5kB") == 52_500)
  #expect(DockerRule.parseReclaimed("Total reclaimed space: 0B") == 0)
  #expect(DockerRule.parseReclaimed("garbage") == 0)
}
```

- [ ] **Step 2:** Run `swift test --filter "DevCachesTests|DockerTests"`. Expected: FAIL to compile.
- [ ] **Step 3:** Implement as specified.
- [ ] **Step 4:** Run the same filter. Expected: PASS.
- [ ] **Step 5:** Commit: `feat: developer cache and Docker rules`.

---

### Task 6: State store and scheduler

**Files:** Create `Sources/CleanerCore/Store.swift`, `Sources/CleanerCore/Scheduler.swift`, `Tests/CleanerCoreTests/StoreTests.swift`, `Tests/CleanerCoreTests/SchedulerTests.swift`

**Produces:**

```swift
public struct DiskSample: Codable, Sendable, Equatable { public var day: Date; public var freeBytes: Int64 }
public struct AppState: Codable, Sendable, Equatable {
  public var history: [RunRecord] = []; public var inventory = AppInventory(); public var diskSamples: [DiskSample] = []
  public var paused = false; public var lastScheduledRun: Date?; public var lastWeeklyRun: Date?
  public init()
  public mutating func prune(now: Date)   // history older than 365 days and samples older than 30 days dropped
}
public struct Store: Sendable {
  public init(directory: URL)
  public func load() -> AppState            // missing or unreadable file → AppState()
  public func save(_ state: AppState) throws // state.json, ISO 8601 dates, atomic write, creates the directory
  public static func defaultDirectory() -> URL   // ~/Library/Application Support/com.maccleaner.app
}
public enum Scheduler {
  public static func shouldRun(now: Date, lastRun: Date?, paused: Bool, calendar: Calendar) -> Bool
  public static func weeklyDue(now: Date, lastWeeklyRun: Date?) -> Bool
}
```

`shouldRun`: false when paused; false when `lastRun` is nil (the app stamps it on first launch, Task 9); true when `lastRun` is after `now`; otherwise true when the most recent 03:00 at or before `now` is later than `lastRun`. `weeklyDue`: nil → true, else `now - last >= Limits.weekly`.

- [ ] **Step 1: Write the failing tests** (calendar: Gregorian, `Asia/Manila`; `at("2026-11-06 02:59")` builds a date in it):

```swift
@Test func roundTrip()                 // save then load == state
@Test func missingFileGivesEmptyState()
@Test func corruptFileGivesEmptyState() // write "{{{" to state.json → load() == AppState(), no throw
@Test func pruneDropsOldEntries()      // history at 366 and 364 days → one left; samples at 31 and 29 days → one left
@Test func neverStampedDoesNotRun()    { #expect(!Scheduler.shouldRun(now: at("2026-11-06 12:00"), lastRun: nil, paused: false, calendar: cal)) }
@Test func pausedDoesNotRun()          // lastRun three days ago, paused → false
@Test func runsAtThreeNotBefore()      // lastRun 11-05 03:00: now 11-06 02:59 → false; now 11-06 03:00 → true
@Test func oncePerDay()                // lastRun 11-06 03:00, now 11-06 23:00 → false
@Test func catchesUpAfterSleep()       // lastRun 11-03 03:00, now 11-06 08:00 → true
@Test func clockMovedBackRuns()        // lastRun 11-07 03:00, now 11-06 12:00 → true
@Test func weeklyBoundary()            // nil → true; 6 days → false; 7 days → true
```

- [ ] **Step 2:** Run `swift test --filter "StoreTests|SchedulerTests"`. Expected: FAIL to compile.
- [ ] **Step 3:** Implement as specified.
- [ ] **Step 4:** Run the same filter. Expected: PASS.
- [ ] **Step 5:** Commit: `feat: state store and scheduler`.

---

### Task 7: Clean session

**Files:** Create `Sources/CleanerCore/CleanSession.swift`, `Tests/CleanerCoreTests/CleanSessionTests.swift`

**Consumes:** everything from Tasks 2 to 6.

**Produces:**

```swift
public struct CleanEnvironment: Sendable {
  public var home: URL; public var bootVolume: URL; public var appDirs: [URL]
  public var runningBundleIDs: @Sendable () -> Set<String>
  public var appExistsAnywhere: @Sendable (String) -> Bool   // LaunchServices lookup or currently running
  public var runner: any CommandRunner
  public var hooks: DeletionGateway.Hooks
  public var trashDateAdded: @Sendable (URL) -> Date?
  public var mode: DeletionGateway.Mode
  public static func live(mode: DeletionGateway.Mode) -> CleanEnvironment
  public var allowedRoots: [URL] { get }; public var deniedRoots: [URL] { get }
}
public enum CleanSession {
  public static func run(env: CleanEnvironment, state: inout AppState, now: Date, manual: Bool) -> (record: RunRecord, touched: [URL])
}
```

`allowedRoots`, all under `home`: `Library/Caches`, `Library/Logs`, `.Trash`, `Library/Application Support`, `Library/Preferences`, `Library/Saved Application State`, `Library/HTTPStorages`, `Library/WebKit`, plus `DevCacheRule.wholeCacheDirs` and `derivedDataDir`. `deniedRoots`: `Documents`, `Desktop`, `Downloads`, `Pictures`, `Movies`, `Music`, `Library/Mail`, `Library/Messages`, `Library/Mobile Documents`, `Library/Keychains`, `Library/Safari`, `Library/Containers`, `Library/Group Containers`, and under `Library/Application Support`: `Google/Chrome`, `Firefox`, `BraveSoftware`, `Microsoft Edge`, `Arc`.

`live`: `home` is the user's home; `bootVolume` is the volume of `home`; `appDirs` are `/Applications` and `~/Applications`; `runningBundleIDs` from `NSWorkspace.shared.runningApplications`; `appExistsAnywhere` from `NSWorkspace.shared.urlForApplication(withBundleIdentifier:)` or the running list.

`run`, in order: scan apps and `inventory.update`; for each `inventory.due(now)` ID, call `resetClock` when `env.appExistsAnywhere(id)` or `LeftoverRule.recentlyUsed`, else keep it as a leftover; build one gateway and the rules; run daily rules always and weekly rules when `manual` or `Scheduler.weeklyDue`; `markCleaned`; append the record; set `lastScheduledRun = now` when not manual and `lastWeeklyRun = now` when weekly rules ran; `prune`. In `.dryRun` the passed-in `state` is left unchanged.

- [ ] **Step 1: Write the failing tests.** A helper builds a fake home in a `Sandbox` with every allowed root holding old files, plus `Documents/keep.txt`, `Desktop/keep.txt`, `Downloads/keep.txt`, `Library/Application Support/Google/Chrome/Cookies`, `Library/Containers/com.x/data`, and an environment using `s.hooks`, a `FakeRunner`, `appExistsAnywhere: { _ in false }`.

```swift
@Test func dailyRunSkipsWeekly()            // lastWeeklyRun 1 day ago → .npm/_cacache/x exists; record has no devCaches or docker result
@Test func manualRunIncludesWeekly()        // manual: true → .npm/_cacache/x gone
@Test func protectedFoldersUntouched()      // tree() of Documents, Desktop, Downloads, Chrome, Containers identical before and after a manual run
@Test func everyTouchedPathIsUnderAnAllowedRoot()
@Test func dryRunChangesNothing()           // s.tree() identical, state == before, touched is not empty
@Test func otherVolumeMeansNoDeletion()     // hooks.volumeOf returns /Volumes/json SSD → touched.isEmpty, tree identical, errors empty
@Test func leftoverFlow()                   // removed["com.gone.app"] 31 days ago, data aged 40 days → candidates in __trash, ID dropped from removed
@Test func leftoverSparedWhenAppStillExists() // appExistsAnywhere true → data in place, removed["com.gone.app"] == now
@Test func leftoverSparedWhenDataIsFresh()  // data aged 5 days → in place, clock reset
@Test func stampsAndHistory()               // scheduled run sets lastScheduledRun == now and appends one record; manual run leaves lastScheduledRun unchanged
```

- [ ] **Step 2:** Run `swift test --filter CleanSessionTests`. Expected: FAIL to compile.
- [ ] **Step 3:** Implement as specified.
- [ ] **Step 4:** Run `swift test`. Expected: every test PASSES.
- [ ] **Step 5:** Run `grep -rn "removeItem\|trashItem" Sources/`. Expected: matches only in `DeletionGateway.swift`.
- [ ] **Step 6:** Commit: `feat: clean session`.

---

### Task 8: System stats and formatting

**Files:** Create `Sources/CleanerCore/SystemStats.swift`, `Sources/CleanerCore/Format.swift`, `Tests/CleanerCoreTests/StatsFormatTests.swift`

**Produces:**

```swift
public struct StatsSnapshot: Sendable, Equatable {
  public var diskFreeBytes: Int64; public var diskTotalBytes: Int64
  public var memoryUsedFraction: Double; public var cpuFraction: Double; public var batteryFraction: Double?
}
public struct CPUTicks: Sendable, Equatable { public var busy: UInt64; public var total: UInt64 }
public final class SystemStats: @unchecked Sendable {
  public init(volume: URL)
  public func sample() -> StatsSnapshot
  public static func cpuFraction(previous: CPUTicks, current: CPUTicks) -> Double
}
public enum Format {
  public static func bytes(_ n: Int64) -> String                 // ByteCountFormatter, .file style, no "Zero"
  public static func percent(_ f: Double) -> String              // "61%"
  public static func menuBarText(freeBytes: Int64, memoryFraction: Double) -> String
  public static func monthlyTotal(_ history: [RunRecord], now: Date, calendar: Calendar) -> Int64
}
```

Sources: disk from `volumeAvailableCapacityForImportantUsageKey` and `volumeTotalCapacityKey`; memory from `host_statistics64` as (active + wired + compressed) over physical memory; CPU from `host_statistics` `HOST_CPU_LOAD_INFO` tick deltas between calls; battery from `IOPSCopyPowerSourcesInfo`, `nil` when there is no battery.

- [ ] **Step 1: Write the failing tests:**

```swift
@Test func cpuDelta() { #expect(SystemStats.cpuFraction(previous: .init(busy: 100, total: 1000), current: .init(busy: 150, total: 1200)) == 0.25) }
@Test func cpuZeroDelta() { #expect(SystemStats.cpuFraction(previous: .init(busy: 1, total: 1), current: .init(busy: 1, total: 1)) == 0) }
@Test func sampleIsSane() { let s = SystemStats(volume: URL(filePath: "/")).sample(); #expect(s.diskFreeBytes > 0 && s.diskFreeBytes <= s.diskTotalBytes); #expect((0...1).contains(s.memoryUsedFraction)); #expect((0...1).contains(s.cpuFraction)) }
@Test func menuBarText() { #expect(Format.menuBarText(freeBytes: 212_000_000_000, memoryFraction: 0.61) == "212 GB · 61%") }
@Test func byteText() { #expect(Format.bytes(640_000_000) == "640 MB"); #expect(Format.bytes(1_200_000_000) == "1.2 GB") }
@Test func monthlyTotalCountsThisMonthOnly() // records on Nov 2 (10), Nov 5 (5), Oct 30 (99), now Nov 6 → 15
```

- [ ] **Step 2:** Run `swift test --filter StatsFormatTests`. Expected: FAIL to compile.
- [ ] **Step 3:** Implement as specified.
- [ ] **Step 4:** Run the same filter. Expected: PASS.
- [ ] **Step 5:** Commit: `feat: system stats and formatting`.

---

### Task 9: Menu bar app

**Files:** Create `Sources/MacCleaner/AppModel.swift`, `Sources/MacCleaner/PopoverView.swift`, `Sources/MacCleaner/StatTile.swift`, `Resources/Info.plist`, `scripts/bundle.sh`. Modify `Sources/MacCleaner/MacCleanerApp.swift`.

**Consumes:** `CleanSession.run`, `CleanEnvironment.live(mode:)`, `Store`, `Scheduler`, `SystemStats`, `Format`, `TrashRule.hasAccess`.

**Produces:**

```swift
@MainActor @Observable final class AppModel {
  var stats: StatsSnapshot
  var samples: [(date: Date, stats: StatsSnapshot)]   // last 60 minutes
  var state: AppState
  var isCleaning: Bool
  var trashAccess: Bool
  var lastRecord: RunRecord? { get }
  func start(); func cleanNow(); func togglePause(); func openFullDiskAccessSettings()
}
struct StatTile: View { init(title: String, value: String, fraction: Double?) }
```

Behaviour:
- Mode: `#if DEBUG` always `.dryRun`; otherwise `.dryRun` when `MACCLEANER_DRY_RUN=1` or when launched with the argument `--dry-run-report`, else `.live`. After a dry run, write `touched` paths, one per line, to `<store dir>/dry-run.txt`.
- `--dry-run-report`: skip the UI, run `CleanSession.run` once with `manual: true` in `.dryRun`, write `dry-run.txt`, print its path and the total bytes, exit 0. Valid in every build.
- A dry-run process is inert: it never calls `Store.save`, never runs on the schedule (only "Clean now" or `--dry-run-report`), and never registers a login item. It may read the store. This keeps a test launch from stamping `lastScheduledRun` (which would make the first live launch clean at once) and from leaving a login item that later starts the build in live mode.
- `start()`: load state; if `lastScheduledRun` is nil, set it to now and save (so nothing is cleaned at first launch); sample stats every 10 s; check `Scheduler.shouldRun` every 60 s and on `NSWorkspace.didWakeNotification`; append one `DiskSample` per calendar day; register `SMAppService.mainApp` once when its status is `.notRegistered` and the process runs from an `.app` bundle in `.live` mode.
- Cleaning runs off the main actor. A second request while `isCleaning` is ignored. In `.live` mode state is saved after every run. In `.dryRun` the returned record is held in memory as `dryRunRecord`; `lastRecord` is `dryRunRecord ?? state.history.last`, and the full view lists it above the history.
- Menu bar label: SF Symbol `sparkles` plus `Format.menuBarText`. `MenuBarExtra` uses `.menuBarExtraStyle(.window)`.
- Window content, top to bottom, following mockup option B: 2 × 2 tiles titled DISK, MEMORY, CPU, BATTERY (battery tile hidden when `batteryFraction` is nil); a "Last clean" row with time and amount, with a warning symbol when `lastRecord.hasErrors`, expanding on click to one row per category with `displayName` and `Format.bytes`; "Clean now" button, disabled while cleaning; "Open full view" button; gear menu with "Pause auto-clean" or "Resume auto-clean", and "Quit".
- When `trashAccess` is false, show: "Trash is skipped. Grant Full Disk Access to include it." with an "Open Settings" button opening `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`.
- `Info.plist`: `CFBundleIdentifier` `com.maccleaner.app`, `CFBundleName` `Mac Cleaner`, `CFBundleExecutable` `MacCleaner`, `LSUIElement` true, `LSMinimumSystemVersion` `27.0`.
- `scripts/bundle.sh`: `swift build -c release`; assemble `dist/Mac Cleaner.app/Contents/{MacOS/MacCleaner,Info.plist}`; sign with `codesign --force --options runtime --sign "$IDENTITY"`, where `IDENTITY` is `$CODESIGN_IDENTITY`, else the first "Apple Development" identity from `security find-identity -v -p codesigning`, else `-`.

- [ ] **Step 1:** Implement the files above.
- [ ] **Step 2:** Run `swift build` and `swift test`. Expected: build succeeds, all tests pass.
- [ ] **Step 3:** Run `scripts/bundle.sh`, then `"dist/Mac Cleaner.app/Contents/MacOS/MacCleaner" --dry-run-report`. Expected: exit 0, `~/Library/Application Support/com.maccleaner.app/dry-run.txt` exists, `state.json` does not exist. Then launch `MACCLEANER_DRY_RUN=1 "dist/Mac Cleaner.app/Contents/MacOS/MacCleaner"` for a few seconds and confirm the process stays alive; quit it. Checking the window by eye (menu bar text like "212 GB · 61%", no Dock icon, four tiles updating, "Clean now" finishing) is left to the controller or owner if the implementer cannot see the screen.
- [ ] **Step 4:** Read `dry-run.txt`. Expected: every line starts with the home folder and sits under an allowed root; no line starts with `/Volumes/`. Report anything surprising to the owner instead of fixing it silently.
- [ ] **Step 5:** Commit: `feat: menu bar app`.

---

### Task 10: Full view window

**Files:** Create `Sources/MacCleaner/FullView.swift`. Modify `MacCleanerApp.swift`, `PopoverView.swift`.

**Consumes:** `AppModel`, `StatTile`, `Format.monthlyTotal`.

Behaviour, following `full-window.html`:
- Scene `Window("Mac Cleaner", id: "full")`, default size 760 × 520, resizable, fullscreen disabled (`.windowFullScreenBehavior(.disabled)`; if unavailable, set `collectionBehavior` to `.fullScreenNone` on the `NSWindow`).
- "Open full view" calls `openWindow(id: "full")` and then `NSApp.activate()` so the window comes to the front.
- Top row: the four tiles, each with a Swift Charts line. Disk plots `state.diskSamples` (30 days). Memory, CPU and battery plot `samples` (60 minutes). Captions "last 30 days" and "last 60 minutes".
- Left panel: last clean header with time and total, then one row per category.
- Right panel: header "Cleaning history" with this month's total from `Format.monthlyTotal`, then one row per run, newest first, with date and `Format.bytes(totalBytes)`.
- Footer: "Clean now" and "Pause auto-clean" / "Resume auto-clean", bound to the same model as the menu bar window.

- [ ] **Step 1:** Implement.
- [ ] **Step 2:** Run `swift build` and `swift test`. Expected: both succeed.
- [ ] **Step 3:** Bundle and launch in dry run as in Task 9. Check by eye: the button opens the window in front; it resizes; the green zoom button does not enter fullscreen; graphs draw; both panels fill after "Clean now"; pausing in one window shows as paused in the other.
- [ ] **Step 4:** Commit: `feat: full view window`.

---

### Task 11: First live run and remote

Every step here needs the owner. Do not do any of them on your own.

- [ ] **Step 1:** Give the owner `~/Library/Application Support/com.maccleaner.app/dry-run.txt` from a fresh dry run, with the total size and the ten largest entries. Wait for an explicit yes. The first live clean is irreversible.
- [ ] **Step 2:** After the yes: `scripts/bundle.sh`, copy `dist/Mac Cleaner.app` to `/Applications`, launch it. The owner grants Full Disk Access in System Settings. The owner clicks "Clean now", or waits for 03:00.
- [ ] **Step 3:** Check after the run: the breakdown matches the dry-run list; `/Volumes/json SSD` is untouched; Documents, Desktop and Downloads are untouched.
- [ ] **Step 4:** With the owner's OK: create a private GitHub repository, push `main`, `staging` and the feature branch, confirm CI is green, open a pull request from `feature/mac-cleaner-v1` into `staging`. The Vercel stages of the owner's pipeline do not apply to this app.
