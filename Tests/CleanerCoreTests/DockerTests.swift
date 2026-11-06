import Foundation
import Testing
@testable import CleanerCore

final class FakeRunner: CommandRunner, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [[String]] = []
  let infoStatus: Int32
  let pruneStatus: Int32
  init(infoStatus: Int32 = 0, pruneStatus: Int32 = 0) {
    self.infoStatus = infoStatus
    self.pruneStatus = pruneStatus
  }
  var calls: [[String]] { lock.withLock { recorded } }
  func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) -> (status: Int32, output: String)? {
    lock.withLock { recorded.append(arguments) }
    if arguments == ["info"] { return (infoStatus, "") }
    // buildx prints "Total:\t<size>" for `builder prune`, classic prune prints "Total reclaimed space:".
    return (pruneStatus, arguments.first == "builder" ? "ID  RECLAIMABLE\nTotal:\t1.2GB\n" : "Total reclaimed space: 1MB")
  }
}

struct DockerTests {
  let box = Sandbox()
  var binary: URL {
    let url = box.file("bin/docker")
    try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
    return url
  }

  func rule(_ runner: FakeRunner, mode: DeletionGateway.Mode = .live, candidates: [URL]? = nil,
            onBoot: Bool = true) -> DockerRule {
    DockerRule(home: box.root, runner: runner, mode: mode, isOnBootVolume: { _ in onBoot },
               candidates: candidates ?? [binary])
  }
  func gateway() -> DeletionGateway { box.gateway(roots: ["."]) }
  func settings(_ json: String, file: String = "settings-store.json") throws {
    let dir = box.dir("Library/Group Containers/group.com.docker")
    try json.write(to: dir.appending(path: file), atomically: true, encoding: .utf8)
  }

  @Test func noBinaryRunsNothing() {
    let runner = FakeRunner()
    let result = rule(runner, candidates: [box.url("bin/missing")]).run(gateway: gateway(), now: .now)
    #expect(runner.calls.isEmpty)
    #expect(result.bytesFreed == 0 && result.errors.isEmpty)
  }

  @Test func stoppedDaemonRunsNoPrune() {
    let runner = FakeRunner(infoStatus: 1)
    let result = rule(runner).run(gateway: gateway(), now: .now)
    #expect(runner.calls == [["info"]])
    #expect(result.bytesFreed == 0 && result.errors.isEmpty)
  }

  @Test func runsExactlyTwoPrunes() {
    let runner = FakeRunner()
    let result = rule(runner).run(gateway: gateway(), now: .now)
    #expect(runner.calls == [["info"], ["builder", "prune", "-f"], ["image", "prune", "-f"]])
    #expect(result.bytesFreed == 1_201_000_000)
    #expect(result.errors.isEmpty)
  }

  @Test func neverTouchesVolumesOrTaggedImages() {
    let runner = FakeRunner()
    _ = rule(runner).run(gateway: gateway(), now: .now)
    let words = Set(runner.calls.flatMap { $0 })
    for banned in ["volume", "system", "container", "-a", "--all"] { #expect(!words.contains(banned)) }
  }

  @Test func externalDataFolderSkips() throws {
    try settings(#"{"DataFolder": "/Volumes/Ext/Docker"}"#)
    let runner = FakeRunner()
    _ = rule(runner, onBoot: false).run(gateway: gateway(), now: .now)
    #expect(runner.calls == [["info"]])
  }

  @Test func internalDataFolderPrunes() throws {
    try settings(#"{"DataFolder": "/Users/x/Library/Containers/docker"}"#)
    let runner = FakeRunner()
    _ = rule(runner, onBoot: true).run(gateway: gateway(), now: .now)
    #expect(runner.calls.count == 3)
  }

  @Test func legacySettingsFileAndLowercaseKey() throws {
    try settings(#"{"dataFolder": "/Volumes/Ext/Docker"}"#, file: "settings.json")
    let runner = FakeRunner()
    _ = rule(runner, onBoot: false).run(gateway: gateway(), now: .now)
    #expect(runner.calls == [["info"]])
  }

  @Test func unparseableSettingsTouchNothing() throws {
    try settings("{not json")
    let runner = FakeRunner()
    let result = rule(runner).run(gateway: gateway(), now: .now)
    #expect(runner.calls == [["info"]])
    #expect(result.bytesFreed == 0)
  }

  @Test func unreadableSettingsFolderTouchesNothing() throws {
    try settings(#"{"DataFolder": "/Volumes/Ext/Docker"}"#)
    let dir = box.url("Library/Group Containers/group.com.docker").path(percentEncoded: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir) }
    let runner = FakeRunner()
    _ = rule(runner, onBoot: false).run(gateway: gateway(), now: .now)
    #expect(runner.calls == [["info"]])
  }

  @Test func nonStringDataFolderTouchesNothing() throws {
    try settings(#"{"DataFolder": 5}"#)
    let runner = FakeRunner()
    _ = rule(runner).run(gateway: gateway(), now: .now)
    #expect(runner.calls == [["info"]])
  }

  @Test func pruneFailureIsAnError() {
    let runner = FakeRunner(pruneStatus: 1)
    let result = rule(runner).run(gateway: gateway(), now: .now)
    #expect(!result.errors.isEmpty)
  }

  @Test func dryRunStopsAfterInfo() {
    let runner = FakeRunner()
    _ = rule(runner, mode: .dryRun).run(gateway: gateway(), now: .now)
    #expect(runner.calls == [["info"]])
  }

  @Test func parsesReclaimed() {
    #expect(DockerRule.parseReclaimed("Total reclaimed space: 1.2GB") == 1_200_000_000)
    #expect(DockerRule.parseReclaimed("Total reclaimed space: 310MB") == 310_000_000)
    #expect(DockerRule.parseReclaimed("Total reclaimed space: 52.5kB") == 52_500)
    #expect(DockerRule.parseReclaimed("Total reclaimed space: 0B") == 0)
    #expect(DockerRule.parseReclaimed("garbage") == 0)
    #expect(DockerRule.parseReclaimed("Total:\t1.2GB") == 1_200_000_000)
  }
}

struct ProcessRunnerTests {
  @Test func capturesOutput() {
    let r = ProcessRunner().run(URL(filePath: "/bin/echo"), ["hi"], timeout: 5)
    #expect(r?.status == 0 && r?.output == "hi\n")
  }
  @Test func drainsLargeOutput() {
    let r = ProcessRunner().run(URL(filePath: "/bin/sh"), ["-c", "yes x | head -c 300000"], timeout: 10)
    #expect(r?.status == 0 && r?.output.utf8.count == 300_000)
  }
  @Test func grandchildHoldingPipeDoesNotHang() {
    let start = Date()
    let r = ProcessRunner().run(URL(filePath: "/bin/sh"), ["-c", "sleep 6 & exit 0"], timeout: 1)
    #expect(Date().timeIntervalSince(start) < 3)
    #expect(r?.status == 0)
  }
  @Test func timeoutReturnsNil() {
    #expect(ProcessRunner().run(URL(filePath: "/bin/sleep"), ["5"], timeout: 0.3) == nil)
  }
  @Test func launchFailureReturnsNil() {
    #expect(ProcessRunner().run(URL(filePath: "/nonexistent/x"), [], timeout: 1) == nil)
  }
}
