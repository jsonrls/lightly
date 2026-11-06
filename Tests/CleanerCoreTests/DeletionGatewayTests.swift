import Foundation
import Testing
@testable import CleanerCore

private typealias Refusal = DeletionGateway.Refusal

struct DeletionGatewayTests {
  let s = Sandbox()
  let g: DeletionGateway
  init() { g = s.gateway(roots: ["Caches"]) }

  // Read-only folders
  private func lock(_ path: String) { chmod(s.url(path).path(percentEncoded: false), 0o555) }

  @Test func removeTreeClearsReadOnlyFolders() throws {
    s.file("Caches/tool/aa/bin/tool")
    lock("Caches/tool/aa/bin")
    lock("Caches/tool/aa")
    try DeletionGateway.removeTree(s.url("Caches/tool"))
    #expect(!s.exists("Caches/tool"))
  }

  @Test func liveRemoveHookClearsReadOnlyFolders() throws {
    s.file("Caches/tool/aa/tool")
    lock("Caches/tool/aa")
    try DeletionGateway.Hooks.live.remove(s.url("Caches/tool"))
    #expect(!s.exists("Caches/tool"))
  }

  @Test func removeTreeLeavesLinkTargetsAlone() throws {
    s.file("Documents/locked/keep")
    lock("Documents/locked")
    s.link("Caches/tool/link", to: s.url("Documents/locked"))
    lock("Caches/tool")
    try DeletionGateway.removeTree(s.url("Caches/tool"))
    var info = stat()
    let target = s.url("Documents/locked").path(percentEncoded: false)
    lstat(target, &info)
    #expect(!s.exists("Caches/tool"))
    #expect(s.exists("Documents/locked/keep"))
    #expect(info.st_mode & 0o777 == 0o555)
    chmod(target, 0o755)
  }

  private func mode(_ path: String) -> mode_t {
    var info = stat()
    lstat(s.url(path).path(percentEncoded: false), &info)
    return info.st_mode & 0o777
  }

  private func unlock(_ path: String) { chmod(s.url(path).path(percentEncoded: false), 0o755) }

  private func deviceOf(_ path: String) -> dev_t {
    var info = stat()
    lstat(s.url(path).path(percentEncoded: false), &info)
    return info.st_dev
  }

  @Test func removeTreeDoesNotFollowALinkWrittenWithASlash() {
    s.file("Documents/locked/keep")
    lock("Documents/locked")
    let link = s.link("Caches/link", to: s.url("Documents/locked"))
    let slashed = URL(filePath: link.path(percentEncoded: false) + "/")
    DeletionGateway.makeFoldersWritable(slashed, device: deviceOf("Documents"))
    try? DeletionGateway.removeTree(slashed)
    #expect(mode("Documents/locked") == 0o555)
    #expect(s.exists("Documents/locked/keep"))
    unlock("Documents/locked")
  }

  @Test func unreadableFolderStaysUnreadable() {
    s.file("Caches/tool/aa/keep")
    chmod(s.url("Caches/tool/aa").path(percentEncoded: false), 0o000)
    #expect(throws: (any Error).self) { try DeletionGateway.removeTree(s.url("Caches/tool")) }
    #expect(mode("Caches/tool/aa") == 0)
    unlock("Caches/tool/aa")
    #expect(s.exists("Caches/tool/aa/keep"))
  }

  @Test func unsearchableFolderStaysUnsearchable() {
    s.dir("Caches/tool")
    chmod(s.url("Caches/tool").path(percentEncoded: false), 0o400)
    DeletionGateway.makeFoldersWritable(s.url("Caches/tool"), device: deviceOf("Caches"))
    #expect(mode("Caches/tool") == 0o400)
    unlock("Caches/tool")
  }

  @Test func anotherVolumeIsLeftAlone() {
    s.dir("Caches/tool")
    lock("Caches/tool")
    DeletionGateway.makeFoldersWritable(s.url("Caches/tool"), device: 0)
    #expect(mode("Caches/tool") == 0o555)
    unlock("Caches/tool")
  }

  @Test func addsOnlyTheOwnerWriteBit() {
    s.dir("Caches/tool")
    chmod(s.url("Caches/tool").path(percentEncoded: false), 0o500)
    var info = stat()
    lstat(s.url("Caches/tool").path(percentEncoded: false), &info)
    DeletionGateway.makeFoldersWritable(s.url("Caches/tool"), device: info.st_dev)
    #expect(mode("Caches/tool") == 0o700)
  }

  @Test func readOnlyParentOfTheTargetStaysReadOnly() {
    s.file("Caches/parent/tool/x")
    lock("Caches/parent")
    #expect(throws: (any Error).self) { try DeletionGateway.removeTree(s.url("Caches/parent/tool")) }
    #expect(mode("Caches/parent") == 0o555)
    unlock("Caches/parent")
  }

  @Test func hardLinkedFileKeepsItsMode() throws {
    let keep = s.file("Documents/keep")
    chmod(keep.path(percentEncoded: false), 0o400)
    s.dir("Caches/tool")
    try FileManager.default.linkItem(at: keep, to: s.url("Caches/tool/hard"))
    lock("Caches/tool")
    try DeletionGateway.removeTree(s.url("Caches/tool"))
    #expect(!s.exists("Caches/tool"))
    #expect(mode("Documents/keep") == 0o400)
  }

  @Test func dryRunAndRefusalLeaveModesAlone() throws {
    var hooks = s.hooks
    hooks.remove = DeletionGateway.Hooks.live.remove
    s.file("Caches/tool/x")
    s.file("Documents/locked/x")
    lock("Caches/tool")
    lock("Documents/locked")
    let dry = s.gateway(roots: ["Caches"], mode: .dryRun, hooks: hooks)
    let live = s.gateway(roots: ["Caches"], hooks: hooks)
    try dry.delete(s.url("Caches/tool"))
    #expect(throws: Refusal.outsideAllowedRoots) { try live.delete(s.url("Documents/locked")) }
    #expect(mode("Caches/tool") == 0o555)
    #expect(mode("Documents/locked") == 0o555)
    unlock("Caches/tool")
    unlock("Documents/locked")
  }

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
  // String.hasPrefix compares graphemes: a combining mark after the slash merges with it.
  @Test(arguments: ["Lib/Mail/\u{301}x", "Lib/Mail/\u{200D}y", "Lib/Mail/\u{301}dir/child"])
  func refusesDeniedCombiningMarkName(path: String) {
    let g = s.gateway(roots: ["Lib"], denied: ["Lib/Mail"])
    let f = s.file(path)
    #expect(throws: Refusal.denied) { try g.delete(f) }
    #expect(s.exists(path))
  }
  @Test func refusesAncestorOfDeniedCombiningMarkName() {
    let g = s.gateway(roots: ["Lib"], denied: ["Lib/AS/\u{301}G"])
    s.file("Lib/AS/\u{301}G/x")
    #expect(throws: Refusal.denied) { try g.delete(s.url("Lib/AS")) }
    #expect(s.exists("Lib/AS/\u{301}G/x"))
  }
  @Test func deletesCombiningMarkNameInsideRoot() throws {
    let f = s.file("Caches/\u{301}x")
    try g.delete(f)
    #expect(!s.exists("Caches/\u{301}x"))
  }
  // Byte comparison must not lose this: APFS treats NFC and NFD names as the same folder.
  @Test(arguments: [("Lib/Caf\u{E9}", "Lib/Cafe\u{301}"), ("Lib/Cafe\u{301}", "Lib/Caf\u{E9}")])
  func refusesDeniedInAnotherNormalization(onDisk: String, deniedName: String) {
    let g = s.gateway(roots: ["Lib"], denied: [deniedName])
    s.file(onDisk + "/x")
    #expect(throws: Refusal.denied) { try g.delete(s.url(onDisk + "/x")) }
    #expect(throws: Refusal.denied) { try g.delete(s.url(deniedName + "/x")) }
    #expect(s.exists(onDisk + "/x"))
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
  @Test func redirectedCacheIsSilentSkip() {
    let elsewhere = s.url("Elsewhere").path(percentEncoded: false)
    var h = s.hooks
    h.volumeOf = { url in
      URL(filePath: url.path(percentEncoded: false).hasPrefix(elsewhere) ? "/Volumes/json SSD" : "/")
    }
    let g = s.gateway(roots: ["Caches"], hooks: h)
    s.file("Elsewhere/x")
    s.link("Caches/d", to: s.url("Elsewhere"))
    var r = CleanResult(category: .devCaches, bytesFreed: 0, errors: [])
    r.record(s.url("Caches/d/x"), g.delete)
    #expect(r.errors.isEmpty)
    #expect(s.exists("Elsewhere/x"))
    #expect(g.touched.isEmpty)
  }
  @Test func checksSymlinkThenVolumeThenRootsThenDenied() {
    var h = s.hooks
    h.volumeOf = { _ in nil }
    let offVolume = s.gateway(roots: ["Lib"], denied: ["Lib/Mail"], hooks: h)
    let onVolume = s.gateway(roots: ["Lib"], denied: ["Lib/Mail"])
    let link = s.link("Documents/l", to: s.file("Documents/real"))
    let outside = s.url("Documents/real")
    let denied = s.file("Lib/Mail/x")
    #expect(throws: Refusal.symlink) { try offVolume.validate(link) }
    #expect(throws: Refusal.notOnBootVolume) { try offVolume.validate(outside) }
    #expect(throws: Refusal.notOnBootVolume) { try offVolume.validate(denied) }
    #expect(throws: Refusal.outsideAllowedRoots) { try onVolume.validate(outside) }
    #expect(throws: Refusal.denied) { try onVolume.validate(denied) }
  }
  @Test func missingPathFailsClosedBeforeVolume() {
    var h = s.hooks
    h.volumeOf = { _ in nil }
    let g = s.gateway(roots: ["Caches"], hooks: h)
    s.dir("Caches")
    #expect(throws: Refusal.outsideAllowedRoots) { try g.validate(s.url("Caches/gone")) }
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
