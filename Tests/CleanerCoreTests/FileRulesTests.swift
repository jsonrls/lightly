import Foundation
import Testing
@testable import CleanerCore

struct FileRulesTests {
  let box = Sandbox()
  let now = Date()

  func cache() -> CacheRule {
    CacheRule(cachesDir: box.url("Caches"), runningBundleIDs: { ["com.foo.app"] },
              installedBundleIDs: ["com.foo.app", "com.bar.app"])
  }
  func gw(hooks: DeletionGateway.Hooks? = nil) -> DeletionGateway {
    box.gateway(roots: ["Caches", "Logs", "Trash"], hooks: hooks)
  }

  @Test func skipsRunningAppAndItsHelpers() {
    // dir() ages the folder itself: file() ages only the leaf, which would leave the folder fresh.
    for n in ["com.foo.app", "com.foo.app.helper"] {
      box.file("Caches/\(n)/a", ageDays: 30)
      box.dir("Caches/\(n)", ageDays: 30)
    }
    _ = cache().run(gateway: gw(), now: now)
    #expect(box.exists("Caches/com.foo.app") && box.exists("Caches/com.foo.app.helper"))
  }

  @Test func deletesInstalledIdleApp() {
    box.file("Caches/com.bar.app/a")
    let r = cache().run(gateway: gw(), now: now)
    #expect(!box.exists("Caches/com.bar.app"))
    #expect(r.bytesFreed > 0)
  }

  @Test func skipsAppleAndSkipList() {
    let names = ["com.apple.Safari", "CloudKit", "ms-playwright", "ms-playwright-go", "Cypress", "Homebrew"]
    for n in names {
      box.file("Caches/\(n)/a", ageDays: 30)
      box.dir("Caches/\(n)", ageDays: 30)
    }
    _ = cache().run(gateway: gw(), now: now)
    for n in names { #expect(box.exists("Caches/\(n)"), "\(n)") }
  }

  @Test func unmatchedNeedsSevenIdleDays() {
    box.file("Caches/SomeTool", ageDays: 8)
    box.file("Caches/OtherTool", ageDays: 6)
    _ = cache().run(gateway: gw(), now: now)
    #expect(!box.exists("Caches/SomeTool"))
    #expect(box.exists("Caches/OtherTool"))
  }

  @Test func continuesAfterFailure() {
    box.file("Caches/com.bar.app/a")
    box.file("Caches/SomeTool", ageDays: 8)
    // Fails the first remove whichever entry the listing yields first, so order cannot hide an early abort.
    final class Once: @unchecked Sendable {
      private let lock = NSLock()
      private var fired = false
      func first() -> Bool { lock.withLock { defer { fired = true }; return !fired } }
    }
    let once = Once()
    var hooks = box.hooks
    let real = hooks.remove
    hooks.remove = { url in
      if once.first() { throw CocoaError(.fileWriteNoPermission) }
      try real(url)
    }
    let r = cache().run(gateway: gw(hooks: hooks), now: now)
    #expect(r.errors.count == 1)
    // Exactly one of the two survives: the failed one. The other proves the loop went on.
    #expect(box.exists("Caches/com.bar.app") != box.exists("Caches/SomeTool"))
  }

  @Test func symlinkEntryIsSilent() {
    let docs = box.file("Documents/keep.txt")
    box.link("Caches/l", to: docs.deletingLastPathComponent())
    let r = cache().run(gateway: gw(), now: now)
    #expect(r.errors.isEmpty)
    #expect(box.exists("Documents/keep.txt"))
  }

  @Test func oldLogDeletedFreshKept() {
    box.file("Logs/a/old.log", ageDays: 8)
    box.file("Logs/a/new.log", ageDays: 6)
    _ = LogRule(logsDir: box.url("Logs")).run(gateway: gw(), now: now)
    #expect(!box.exists("Logs/a/old.log"))
    #expect(box.exists("Logs/a/new.log") && box.exists("Logs/a"))
  }

  @Test func trashThirtyDayBoundary() {
    box.file("Trash/old")
    box.file("Trash/recent")
    box.file("Trash/unknown")
    let added: [String: Double] = ["old": 30, "recent": 29]
    let rule = TrashRule(trashDir: box.url("Trash"), dateAdded: { url in
      added[url.lastPathComponent].map { now.addingTimeInterval(-$0 * Limits.day) }
    })
    _ = rule.run(gateway: gw(), now: now)
    #expect(!box.exists("Trash/old"))
    #expect(box.exists("Trash/recent") && box.exists("Trash/unknown"))
  }

  @Test func unreadableTrashIsQuiet() {
    let dir = box.url("Trash")
    let r = TrashRule(trashDir: dir).run(gateway: gw(), now: now)
    #expect(r.bytesFreed == 0 && r.errors.isEmpty)
    #expect(!TrashRule.hasAccess(trashDir: dir))
  }
}
