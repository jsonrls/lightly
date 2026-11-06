import Foundation
import Testing
@testable import CleanerCore

private typealias Refusal = DeletionGateway.Refusal

struct DeletionGatewayTests {
  let s = Sandbox()
  let g: DeletionGateway
  init() { g = s.gateway(roots: ["Caches"]) }

  // Allowed roots
  @Test func deletesInsideRoot() throws {
    let f = s.file("Caches/a/x")
    #expect(try g.delete(f) > 0)
    #expect(!s.exists("Caches/a/x"))
  }
  @Test func refusesOutsideRoots() {
    let f = s.file("Documents/x")
    #expect(throws: Refusal.outsideAllowedRoots) { try g.delete(f) }
    #expect(s.exists("Documents/x"))
  }
  @Test func refusesRootItself() {
    s.dir("Caches")
    #expect(throws: Refusal.outsideAllowedRoots) { try g.delete(s.url("Caches")) }
    #expect(s.exists("Caches"))
  }
  @Test func refusesSiblingSharingRootPrefix() {
    s.dir("Caches")
    let f = s.file("Caches2/x")
    #expect(throws: Refusal.outsideAllowedRoots) { try g.delete(f) }
    #expect(s.exists("Caches2/x"))
  }
  @Test func refusesDotDotEscape() {
    s.dir("Caches")
    s.file("Documents/x")
    let escape = s.root.appending(path: "Caches/../Documents/x")
    #expect(throws: Refusal.outsideAllowedRoots) { try g.delete(escape) }
    #expect(s.exists("Documents/x"))
  }
  @Test func refusesDotDotBackToRoot() {
    s.dir("Caches/a")
    #expect(throws: Refusal.outsideAllowedRoots) { try g.delete(s.root.appending(path: "Caches/a/..")) }
    #expect(s.exists("Caches/a"))
  }
  @Test func refusesMissingPath() {
    let g = s.gateway(roots: ["Caches"], mode: .dryRun)
    s.dir("Caches")
    #expect(throws: Refusal.outsideAllowedRoots) { try g.delete(s.url("Caches/gone")) }
    #expect(g.touched.isEmpty)
  }

  // Denied roots
  @Test func refusesDenied() {
    let g = s.gateway(roots: ["Lib"], denied: ["Lib/Mail"])
    let f = s.file("Lib/Mail/x")
    #expect(throws: Refusal.denied) { try g.delete(f) }
    #expect(s.exists("Lib/Mail/x"))
  }
  @Test func refusesDeniedRootItself() {
    let g = s.gateway(roots: ["Lib"], denied: ["Lib/Mail"])
    s.dir("Lib/Mail")
    #expect(throws: Refusal.denied) { try g.delete(s.url("Lib/Mail")) }
    #expect(s.exists("Lib/Mail"))
  }
  @Test func refusesAncestorOfDenied() throws {
    let g = s.gateway(roots: ["Lib"], denied: ["Lib/AS/Google/Chrome"])
    s.file("Lib/AS/Google/Chrome/Cookies")
    #expect(throws: Refusal.denied) { try g.delete(s.url("Lib/AS/Google")) }
    #expect(s.exists("Lib/AS/Google/Chrome/Cookies"))
    s.file("Lib/AS/Other/x")
    try g.delete(s.url("Lib/AS/Other"))
    #expect(!s.exists("Lib/AS/Other"))
  }
  @Test func allowsSiblingOfDenied() throws {
    let g = s.gateway(roots: ["Lib"], denied: ["Lib/Mail"])
    s.dir("Lib/Mail")
    let f = s.file("Lib/Mail2/x")
    try g.delete(f)
    #expect(!s.exists("Lib/Mail2/x"))
  }
  @Test func deniedSlashCoversEverything() {
    let g = DeletionGateway(allowedRoots: [s.url("Caches")], deniedRoots: [URL(filePath: "/")],
                            bootVolume: URL(filePath: "/"), mode: .dryRun, hooks: s.hooks)
    let f = s.file("Caches/x")
    #expect(throws: Refusal.denied) { try g.validate(f) }
  }
  @Test func refusesDeniedThroughSymlinkedParent() {
    let g = s.gateway(roots: ["Lib"], denied: ["Lib/Mail"])
    s.file("Lib/Mail/x")
    s.link("Lib/d", to: s.url("Lib/Mail"))
    #expect(throws: Refusal.denied) { try g.delete(s.url("Lib/d/x")) }
    #expect(s.exists("Lib/Mail/x"))
  }
  @Test func refusesDeniedRootReachedThroughSymlink() {
    let g = s.gateway(roots: ["Lib"], denied: ["Lib/Alias"])
    s.file("Lib/Mail/x")
    s.link("Lib/Alias", to: s.url("Lib/Mail"))
    #expect(throws: Refusal.denied) { try g.delete(s.url("Lib/Mail/x")) }
    #expect(s.exists("Lib/Mail/x"))
  }
  // APFS is case-insensitive by default, so a case variant names the same denied folder.
  @Test func refusesDeniedInAnotherCase() {
    let g = s.gateway(roots: ["Lib"], denied: ["Lib/Mail"])
    s.file("Lib/Mail/x")
    #expect(throws: (any Error).self) { try g.delete(s.url("Lib/MAIL/x")) }
    #expect(s.exists("Lib/Mail/x"))
  }

  // Symlinks
  @Test func refusesSymlinkTarget() {
    let t = s.file("Documents/real")
    let l = s.link("Caches/l", to: t)
    #expect(throws: Refusal.symlink) { try g.delete(l) }
    #expect(s.exists("Documents/real"))
    #expect(s.exists("Caches/l"))
  }
  @Test func refusesSymlinkWithTrailingSlash() {
    s.file("Caches/real/x")
    s.link("Caches/l", to: s.url("Caches/real"))
    let slashed = URL(filePath: s.url("Caches/l").path(percentEncoded: false) + "/")
    #expect(throws: Refusal.symlink) { try g.delete(slashed) }
    #expect(s.exists("Caches/real/x"))
  }
  @Test func refusesDanglingSymlink() {
    s.dir("Caches")
    let l = s.link("Caches/l", to: s.url("Nowhere"))
    #expect(throws: Refusal.symlink) { try g.delete(l) }
  }
  @Test func refusesThroughSymlinkedParent() {
    s.file("Elsewhere/x")
    s.link("Caches/d", to: s.url("Elsewhere"))
    #expect(throws: Refusal.outsideAllowedRoots) { try g.delete(s.url("Caches/d/x")) }
    #expect(s.exists("Elsewhere/x"))
  }
  @Test func refusesSymlinkedRoot() {
    s.file("Elsewhere/x")
    s.link("Caches", to: s.url("Elsewhere"))
    #expect(throws: Refusal.outsideAllowedRoots) { try g.delete(s.url("Caches/x")) }
    #expect(s.exists("Elsewhere/x"))
  }
  @Test func nestedLinkTargetSurvives() throws {
    let t = s.file("Documents/real")
    s.link("Caches/a/l", to: t)
    try g.delete(s.url("Caches/a"))
    #expect(s.exists("Documents/real"))
    #expect(!s.exists("Caches/a"))
  }

  // Volume
  @Test func refusesOtherVolume() {
    var h = s.hooks
    h.volumeOf = { _ in URL(filePath: "/Volumes/json SSD") }
    let g = s.gateway(roots: ["Caches"], hooks: h)
    let f = s.file("Caches/x")
    #expect(throws: Refusal.notOnBootVolume) { try g.delete(f) }
    #expect(s.exists("Caches/x"))
  }
  @Test func refusesUnknownVolume() {
    var h = s.hooks
    h.volumeOf = { _ in nil }
    let g = s.gateway(roots: ["Caches"], hooks: h)
    let f = s.file("Caches/x")
    #expect(throws: Refusal.notOnBootVolume) { try g.delete(f) }
    #expect(s.exists("Caches/x"))
  }
  @Test func asksVolumeOfResolvedPath() throws {
    let seen = Seen()
    var h = s.hooks
    h.volumeOf = { seen.add($0); return URL(filePath: "/") }
    let g = s.gateway(roots: ["Caches"], hooks: h)
    s.file("Caches/real/x")
    s.link("Caches/d", to: s.url("Caches/real"))
    try g.validate(s.url("Caches/d/x"))
    #expect(seen.paths == [s.root.path(percentEncoded: false) + "Caches/real/x"])
  }
  @Test func liveVolumeOfUnreadablePathIsNil() {
    #expect(DeletionGateway.Hooks.live.volumeOf(s.url("missing")) == nil)
  }
  @Test func checksRunInBriefOrder() {
    var h = s.hooks
    h.volumeOf = { _ in nil }
    let g = s.gateway(roots: ["Lib"], denied: ["Lib/Mail"], hooks: h)
    let link = s.link("Documents/l", to: s.file("Documents/real"))
    let outside = s.url("Documents/real")
    let denied = s.file("Lib/Mail/x")
    #expect(throws: Refusal.symlink) { try g.validate(link) }
    #expect(throws: Refusal.outsideAllowedRoots) { try g.validate(outside) }
    #expect(throws: Refusal.denied) { try g.validate(denied) }
  }

  // Modes, size, touched
  @Test func dryRunKeepsFile() throws {
    let g = s.gateway(roots: ["Caches"], mode: .dryRun)
    let f = s.file("Caches/x", bytes: 4096)
    #expect(try g.delete(f) >= 4096)
    #expect(s.exists("Caches/x"))
    #expect(g.touched == [f])
  }
  @Test func dryRunTrashKeepsFile() throws {
    let g = s.gateway(roots: ["Caches"], mode: .dryRun)
    let f = s.file("Caches/x", bytes: 4096)
    #expect(try g.trash(f) >= 4096)
    #expect(s.exists("Caches/x"))
    #expect(!s.exists("__trash/x"))
    #expect(g.touched == [f])
  }
  @Test func sizeSumsFolderWithoutFollowingLinks() throws {
    s.file("Caches/a/x", bytes: 4096)
    s.file("Caches/a/b/y", bytes: 4096)
    s.link("Caches/a/l", to: s.file("Documents/big", bytes: 1_000_000))
    let size = try g.delete(s.url("Caches/a"))
    #expect(size >= 8192)
    #expect(size < 1_000_000)
  }
  @Test func liveDeleteAndTrashAreTouched() throws {
    let a = s.file("Caches/a"), b = s.file("Caches/b")
    try g.delete(a)
    try g.trash(b)
    #expect(g.touched == [a, b])
  }
  @Test func refusedAndFailedAreNotTouched() {
    var h = s.hooks
    h.remove = { _ in throw CocoaError(.fileWriteNoPermission) }
    let g = s.gateway(roots: ["Caches"], hooks: h)
    let f = s.file("Caches/x"), out = s.file("Documents/x")
    #expect(throws: CocoaError.self) { try g.delete(f) }
    #expect(throws: Refusal.outsideAllowedRoots) { try g.delete(out) }
    #expect(g.touched.isEmpty)
  }
  @Test func touchedSurvivesConcurrentUse() {
    let g = s.gateway(roots: ["Caches"], mode: .dryRun)
    let files = (0..<200).map { s.file("Caches/\($0)", bytes: 1) }
    DispatchQueue.concurrentPerform(iterations: files.count) { _ = try? g.delete(files[$0]) }
    #expect(Set(g.touched) == Set(files))
    #expect(g.touched.count == files.count)
  }

  // Trash
  @Test func trashUsesTrashHook() throws {
    let f = s.file("Caches/x")
    try g.trash(f)
    #expect(s.exists("__trash/x"))
    #expect(!s.exists("Caches/x"))
  }
  @Test func trashRefusesOutsideRoots() {
    let f = s.file("Documents/x")
    #expect(throws: Refusal.outsideAllowedRoots) { try g.trash(f) }
    #expect(s.exists("Documents/x"))
  }

  // CleanResult.record
  @Test func recordSkipsSilently() {
    var r = CleanResult(category: .logs, bytesFreed: 0, errors: [])
    let link = s.link("Caches/l", to: s.file("Caches/t"))
    r.record(link, g.delete)
    #expect(r.errors.isEmpty)

    var h = s.hooks
    h.volumeOf = { _ in nil }
    r.record(s.url("Caches/t"), s.gateway(roots: ["Caches"], hooks: h).delete)
    #expect(r.errors.isEmpty)

    let denied = s.gateway(roots: ["Lib"], denied: ["Lib/Mail"])
    r.record(s.file("Lib/Mail/x"), denied.delete)
    #expect(r.errors.count == 1)
    #expect(r.errors.first?.hasPrefix("x: ") == true)
    #expect(r.bytesFreed == 0)
  }
  @Test func recordAddsBytes() {
    var r = CleanResult(category: .logs, bytesFreed: 10, errors: [])
    r.record(s.url("anything")) { _ in 5 }
    #expect(r.bytesFreed == 15)
    #expect(r.errors.isEmpty)
  }

  // Sandbox
  @Test func sandboxTrashNumbersCollisions() throws {
    for dir in ["a", "b", "c"] { try g.trash(s.file("Caches/\(dir)/x")) }
    #expect(s.exists("__trash/x"))
    #expect(s.exists("__trash/x 2"))
    #expect(s.exists("__trash/x 3"))
  }
  @Test func sandboxTreeListsLinksWithoutFollowing() {
    s.file("Elsewhere/x")
    s.link("a/l", to: s.url("Elsewhere"))
    #expect(s.tree() == ["Elsewhere", "Elsewhere/x", "a", "a/l"])
  }
  @Test func sandboxAgesFilesAndFolders() throws {
    let f = s.file("a/x", ageDays: 8), d = s.dir("b", ageDays: 8)
    for url in [f, d] {
      let date = try #require(try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
      #expect(abs(Date().timeIntervalSince(date) - 8 * 86_400) < 60)
    }
  }
  @Test func sandboxRootHasNoSymlinks() throws {
    let path = s.root.path(percentEncoded: false)
    let canonical = try #require(try s.root.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath)
    #expect(path == canonical + "/")
  }
}

private final class Seen: @unchecked Sendable {
  private let lock = NSLock()
  private var urls: [URL] = []
  func add(_ url: URL) { lock.withLock { urls.append(url) } }
  var paths: [String] { lock.withLock { urls.map { $0.path(percentEncoded: false) } } }
}
