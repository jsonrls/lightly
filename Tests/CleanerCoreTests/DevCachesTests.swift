import Foundation
import Testing
@testable import CleanerCore

struct DevCachesTests {
  let box = Sandbox()
  // Trailing slash differs between a directory URL and a plain one.
  func p(_ url: URL) -> String { url.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
  func paths(_ urls: [URL]) -> [String] { urls.map(p) }
  func run(env: [String: String] = [:], mode: DeletionGateway.Mode = .live) -> CleanResult {
    DevCacheRule(home: box.root, environment: env)
      .run(gateway: box.gateway(roots: ["."], mode: mode), now: .now)
  }

  @Test func clearsChildrenKeepsDirs() {
    let dirs = [".npm/_cacache", "Library/Caches/pip", "Library/Caches/Homebrew", "Library/Caches/Yarn", "Library/pnpm/store"]
    for d in dirs { box.file("\(d)/sub/a.bin"); box.file("\(d)/b.bin") }
    let result = run()
    #expect(result.errors.isEmpty)
    #expect(result.bytesFreed > 0)
    for d in dirs {
      #expect(box.exists(d))
      #expect(!box.exists("\(d)/sub") && !box.exists("\(d)/b.bin"))
    }
  }

  @Test func missingToolIsNotAnError() { #expect(run().errors.isEmpty) }

  @Test func npmrcCacheHonoured() throws {
    try "cache=\(box.url("custom").path(percentEncoded: false))\n".write(to: box.url(".npmrc"), atomically: true, encoding: .utf8)
    let dirs = DevCacheRule.wholeCacheDirs(home: box.root, environment: [:])
    #expect(paths(dirs).contains(p(box.url("custom/_cacache"))))
    #expect(!paths(dirs).contains(p(box.url(".npm/_cacache"))))
  }

  @Test func envBeatsNpmrc() throws {
    try "cache=\(box.url("custom").path(percentEncoded: false))\n".write(to: box.url(".npmrc"), atomically: true, encoding: .utf8)
    let dirs = DevCacheRule.wholeCacheDirs(home: box.root, environment: ["npm_config_cache": box.url("fromenv").path(percentEncoded: false)])
    #expect(paths(dirs).contains(p(box.url("fromenv/_cacache"))))
    #expect(!paths(dirs).contains(p(box.url("custom/_cacache"))))
  }

  @Test func derivedDataSevenDayBoundary() {
    // File first: creating it would otherwise refresh the folder's own date.
    box.file("Library/Developer/Xcode/DerivedData/Old-abc/x.o", ageDays: 8)
    box.dir("Library/Developer/Xcode/DerivedData/Old-abc", ageDays: 8)
    box.file("Library/Developer/Xcode/DerivedData/New-def/x.o", ageDays: 6)
    box.dir("Library/Developer/Xcode/DerivedData/New-def", ageDays: 6)
    let result = run()
    #expect(result.errors.isEmpty)
    #expect(!box.exists("Library/Developer/Xcode/DerivedData/Old-abc"))
    #expect(box.exists("Library/Developer/Xcode/DerivedData/New-def"))
    #expect(box.exists("Library/Developer/Xcode/DerivedData"))
  }

  @Test func derivedDataKeepsFolderWithFreshFile() {
    box.file("Library/Developer/Xcode/DerivedData/Mixed-1/fresh.o", ageDays: 1)
    box.dir("Library/Developer/Xcode/DerivedData/Mixed-1", ageDays: 9)
    _ = run()
    #expect(box.exists("Library/Developer/Xcode/DerivedData/Mixed-1"))
  }

  @Test func dryRunDeletesNothing() {
    box.file(".npm/_cacache/a.bin")
    let result = run(mode: .dryRun)
    #expect(result.bytesFreed > 0)
    #expect(box.exists(".npm/_cacache/a.bin"))
  }
}
