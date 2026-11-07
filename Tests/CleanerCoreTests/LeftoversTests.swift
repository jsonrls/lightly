import Foundation
import Testing
@testable import CleanerCore

struct LeftoversTests {
  let t = Date(timeIntervalSince1970: 1_800_000_000)

  func inv(_ ids: Set<String>) -> AppInventory {
    var i = AppInventory()
    i.update(present: ids, now: t)
    return i
  }

  @Test func firstScanMarksNothingRemoved() {
    #expect(inv(["a.b"]).removed.isEmpty)
  }

  @Test func disappearanceIsDated() {
    var i = inv(["a.b"])
    i.update(present: ["x.y"], now: t)
    #expect(i.removed["a.b"] == t)
    i.update(present: ["x.y"], now: t.addingTimeInterval(Limits.day))
    #expect(i.removed["a.b"] == t)
  }

  @Test func returningAppResetsClock() {
    var i = inv(["a.b"])
    i.update(present: ["x.y"], now: t)
    i.update(present: ["a.b", "x.y"], now: t.addingTimeInterval(Limits.day))
    #expect(i.removed["a.b"] == nil)
  }

  @Test func emptyScanChangesNothing() {
    var i = inv(["a.b"])
    let before = i
    i.update(present: [], now: t.addingTimeInterval(Limits.day))
    #expect(i == before)
  }

  @Test func dueAtThirtyDays() {
    var i = AppInventory()
    i.removed["a.b"] = t
    #expect(i.due(now: t.addingTimeInterval(29 * Limits.day)).isEmpty)
    #expect(i.due(now: t.addingTimeInterval(30 * Limits.day)) == ["a.b"])
  }

  @Test func appleNeverDue() {
    var i = AppInventory()
    i.removed["com.apple.Foo"] = t
    #expect(i.due(now: t.addingTimeInterval(90 * Limits.day)).isEmpty)
  }

  // The boot volume ignores case, so Com.apple.Foo names Apple's own com.apple.foo folders.
  @Test func appleInAnyCaseNeverDue() {
    var i = AppInventory()
    i.removed = ["Com.apple.Foo": t, "COM.APPLE.bar": t, "group.com.apple.notes": t, "com.apple": t]
    #expect(i.due(now: t.addingTimeInterval(90 * Limits.day)).isEmpty)
  }

  @Test func resetAndMarkCleaned() {
    var i = AppInventory()
    i.removed = ["a.b": t, "c.d": t]
    i.resetClock("a.b", now: t.addingTimeInterval(Limits.day))
    #expect(i.removed["a.b"] == t.addingTimeInterval(Limits.day))
    i.markCleaned(["c.d"])
    #expect(i.removed["c.d"] == nil)
  }

  @Test func scanReadsBundleIDs() throws {
    let sb = Sandbox()
    func app(_ path: String, id: String) throws {
      sb.dir(path + "/Contents")
      let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id], format: .xml, options: 0)
      try plist.write(to: sb.url(path + "/Contents/Info.plist"))
    }
    try app("Apps/Foo.app", id: "com.foo")
    try app("Apps/Utilities/Bar.app", id: "com.bar")
    sb.dir("Apps/Empty.app/Contents")
    #expect(InstalledApps.scan([sb.url("Apps"), sb.url("Missing")]) == ["com.foo", "com.bar"])
  }

  func app(_ sb: Sandbox, _ path: String, id: String) throws {
    sb.dir(path + "/Contents")
    let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id], format: .xml, options: 0)
    try plist.write(to: sb.url(path + "/Contents/Info.plist"))
  }

  @Test func scanIgnoresDepthThreeAndLinkedApps() throws {
    let sb = Sandbox()
    try app(sb, "Apps/Foo.app", id: "com.foo")
    try app(sb, "Apps/A/B/Deep.app", id: "com.deep")
    try app(sb, "Elsewhere/Real.app", id: "com.real")
    sb.link("Apps/Link.app", to: sb.url("Elsewhere/Real.app"))
    #expect(InstalledApps.scan([sb.url("Apps")]) == ["com.foo"])
  }

  @Test func unreadableFolderScansEmpty() throws {
    for locked in ["Sys", "User/Utilities"] {
      let sb = Sandbox()
      try app(sb, "Sys/Foo.app", id: "com.foo")
      try app(sb, "User/Bar.app", id: "com.bar")
      try app(sb, "User/Utilities/Baz.app", id: "com.baz")
      let path = sb.url(locked).path(percentEncoded: false)
      var inventory = inv(["com.foo", "com.bar", "com.baz"])
      let before = inventory
      try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path)
      defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path) }
      let found = InstalledApps.scan([sb.url("Sys"), sb.url("User")])
      #expect(found.isEmpty, "\(locked)")
      inventory.update(present: found, now: t.addingTimeInterval(Limits.day))
      #expect(inventory == before)
    }
  }

  @Test func cleanedAppDoesNotRearm() {
    var i = inv(["a.b", "x.y"])
    i.update(present: ["x.y"], now: t)
    i.markCleaned(["a.b"])
    i.update(present: ["x.y"], now: t.addingTimeInterval(Limits.day))
    #expect(i.removed.isEmpty)
  }

  @Test func partialCandidatesTrashWithoutErrors() {
    let sb = Sandbox()
    for p in ["Caches/com.gone.app/x", "Logs/com.gone.app/x"] { sb.file("Library/" + p, ageDays: 40); sb.dir("Library/" + p.split(separator: "/x")[0], ageDays: 40) }
    let r = LeftoversRule(sb).run(gateway: sb.gateway(roots: ["Library"]), now: Date())
    #expect(r.errors.isEmpty && r.bytesFreed > 0)
    #expect(!sb.exists("Library/Caches/com.gone.app") && !sb.exists("Library/Logs/com.gone.app"))
  }

  @Test func unreadableDataCountsAsRecent() {
    let sb = Sandbox()
    sb.file("Library/Application Support/com.gone.app/db/live.sqlite")
    sb.dir("Library/Application Support/com.gone.app/db", ageDays: 40)
    sb.dir("Library/Application Support/com.gone.app", ageDays: 40)
    let locked = sb.url("Library/Application Support/com.gone.app/db").path(percentEncoded: false)
    try! FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked) }
    #expect(LeftoverRule.recentlyUsed(libraryDir: sb.url("Library"), bundleID: "com.gone.app", now: Date()))
    let r = LeftoversRule(sb).run(gateway: sb.gateway(roots: ["Library"]), now: Date())
    #expect(r.bytesFreed == 0 && sb.exists("Library/Application Support/com.gone.app"))
  }

  static let seven = [
    "Application Support/com.gone.app", "Caches/com.gone.app", "Preferences/com.gone.app.plist",
    "Saved Application State/com.gone.app.savedState", "HTTPStorages/com.gone.app", "WebKit/com.gone.app",
    "Logs/com.gone.app",
  ]

  @Test func trashesOnlyTheSevenCandidates() {
    let sb = Sandbox()
    for p in Self.seven {
      if p.hasSuffix(".plist") { sb.file("Library/" + p, ageDays: 40); continue }
      sb.file("Library/\(p)/x", ageDays: 40)
      sb.dir("Library/" + p, ageDays: 40)
    }
    sb.file("Library/Application Support/com.other.app/x", ageDays: 40)
    sb.file("Library/Containers/com.gone.app/x", ageDays: 40)
    let g = sb.gateway(roots: ["Library"])
    let r = LeftoversRule(sb).run(gateway: g, now: Date())
    #expect(r.errors.isEmpty)
    for p in Self.seven { #expect(!sb.exists("Library/" + p)) }
    #expect(sb.tree().filter { $0.hasPrefix("__trash/") && !$0.dropFirst(8).contains("/") }.count == 7)
    #expect(sb.exists("Library/Application Support/com.other.app"))
    #expect(sb.exists("Library/Containers/com.gone.app"))
  }

  @Test func recentlyUsedDataIsKept() {
    let sb = Sandbox()
    sb.file("Library/Caches/com.gone.app/x", ageDays: 5)
    sb.file("Library/Logs/com.gone.app/x", ageDays: 40)
    sb.dir("Library/Logs/com.gone.app", ageDays: 40)
    let r = LeftoversRule(sb).run(gateway: sb.gateway(roots: ["Library"]), now: Date())
    #expect(r.bytesFreed == 0)
    #expect(sb.exists("Library/Caches/com.gone.app") && sb.exists("Library/Logs/com.gone.app"))
  }

  @Test func hostileIDsYieldNothing() {
    let lib = URL(filePath: "/nonexistent/Library")
    for id in ["../../Documents", "a/b", "", "a b", "x..y", ".", "Google", "a.", ".a"] {
      #expect(LeftoverRule.candidates(libraryDir: lib, bundleID: id).isEmpty, "\(id)")
    }
    #expect(LeftoverRule.candidates(libraryDir: lib, bundleID: "com.ok-1.app").count == 7)
  }

  @Test func browserDataIsKept() {
    let sb = Sandbox()
    sb.file("Library/Application Support/com.gone.app/Default/Login Data", ageDays: 40)
    sb.file("Library/Caches/com.gone.app/x", ageDays: 40)
    let g = sb.gateway(roots: ["Library"])
    let r = LeftoversRule(sb).run(gateway: g, now: Date())
    #expect(g.touched.isEmpty && r.errors.isEmpty)
    #expect(sb.exists("Library/Application Support/com.gone.app/Default/Login Data"))
    #expect(sb.exists("Library/Caches/com.gone.app/x"))
  }

  @Test(arguments: ["Login Data", "Cookies", "places.sqlite"])
  func browserFilesAreFoundAtAnyDepth(_ name: String) {
    let sb = Sandbox()
    sb.file("Library/WebKit/com.gone.app/a/b/c/\(name)", ageDays: 40)
    #expect(LeftoverRule.holdsBrowserData(libraryDir: sb.url("Library"), bundleID: "com.gone.app"))
  }

  @Test func foldersLinksAndOtherFilesAreNotBrowserData() {
    let sb = Sandbox()
    sb.file("Elsewhere/Login Data")
    sb.link("Library/Application Support/com.gone.app/profile", to: sb.url("Elsewhere"))
    sb.dir("Library/Application Support/com.gone.app/Cookies")
    sb.file("Library/Application Support/com.gone.app/notes.txt")
    sb.file("Library/Preferences/com.gone.app.plist")
    #expect(!LeftoverRule.holdsBrowserData(libraryDir: sb.url("Library"), bundleID: "com.gone.app"))
  }

  @Test(arguments: ["Library/Application Support/com.gone.app", "Library/Application Support/com.gone.app/db"])
  func unreadableFolderCountsAsBrowserData(_ locked: String) {
    let sb = Sandbox()
    sb.file("Library/Application Support/com.gone.app/db/x", ageDays: 40)
    let path = sb.url(locked).path(percentEncoded: false)
    try! FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path) }
    #expect(LeftoverRule.holdsBrowserData(libraryDir: sb.url("Library"), bundleID: "com.gone.app"))
  }

  @Test func freshFolderDateIsNotUse() {
    let sb = Sandbox()
    sb.file("Library/Logs/com.gone.app/x", ageDays: 40)  // the folder keeps today's date
    sb.dir("Library/Caches/com.gone.app")  // empty and fresh
    #expect(!LeftoverRule.recentlyUsed(libraryDir: sb.url("Library"), bundleID: "com.gone.app", now: Date()))
  }

  @Test func recentlyUsedDetectsFreshData() {
    let sb = Sandbox()
    let lib = sb.url("Library")
    sb.file("Library/Caches/com.gone.app/x", ageDays: 5)
    #expect(LeftoverRule.recentlyUsed(libraryDir: lib, bundleID: "com.gone.app", now: Date()))
    let sb2 = Sandbox()
    sb2.file("Library/Caches/com.gone.app/x", ageDays: 40)
    sb2.dir("Library/Caches/com.gone.app", ageDays: 40)
    #expect(!LeftoverRule.recentlyUsed(libraryDir: sb2.url("Library"), bundleID: "com.gone.app", now: Date()))
  }
}

private func LeftoversRule(_ sb: Sandbox) -> LeftoverRule {
  LeftoverRule(libraryDir: sb.url("Library"), bundleIDs: ["com.gone.app"])
}
