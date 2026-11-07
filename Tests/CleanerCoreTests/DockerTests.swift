import Foundation
import Testing
@testable import CleanerCore

final class FakeRunner: CommandRunner, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [(executable: URL, arguments: [String])] = []
  let infoStatus: @Sendable (String) -> Int32  // by socket path
  let pruneStatus: Int32
  init(infoStatus: Int32 = 0, pruneStatus: Int32 = 0) {
    self.infoStatus = { _ in infoStatus }
    self.pruneStatus = pruneStatus
  }
  init(infoStatusFor: @escaping @Sendable (String) -> Int32) {
    infoStatus = infoStatusFor
    pruneStatus = 0
  }
  var invocations: [(executable: URL, arguments: [String])] { lock.withLock { recorded } }
  /// Each call as its Engine API path, for example "/info".
  var calls: [String] { invocations.map { String(($0.arguments.last ?? "").dropFirst("http://localhost".count)) } }
  func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) -> (status: Int32, output: String)? {
    lock.withLock { recorded.append((executable, arguments)) }
    let path = arguments.last ?? ""
    let socket = arguments.firstIndex(of: "--unix-socket").map { arguments[$0 + 1] } ?? ""
    if path.hasSuffix("/info") { return (infoStatus(socket), "{}") }
    return (pruneStatus, path.hasSuffix("/build/prune")
      ? #"{"CachesDeleted":null,"SpaceReclaimed":1200000000}"# : #"{"ImagesDeleted":null,"SpaceReclaimed":1000000}"#)
  }
}

struct DockerTests {
  let box = Sandbox()
  var socket: URL { box.file("docker.sock") }

  func rule(_ runner: FakeRunner, mode: DeletionGateway.Mode = .live, sockets: [URL]? = nil,
            onBoot: Bool = true) -> DockerRule {
    DockerRule(home: box.root, runner: runner, mode: mode, isOnBootVolume: { _ in onBoot }, sockets: sockets ?? [socket])
  }
  func gateway() -> DeletionGateway { box.gateway(roots: ["."]) }
  func settings(_ json: String, file: String = "settings-store.json") throws {
    let dir = box.dir("Library/Group Containers/group.com.docker")
    try json.write(to: dir.appending(path: file), atomically: true, encoding: .utf8)
  }

  @Test func noSocketRunsNothing() {
    let runner = FakeRunner()
    let result = rule(runner, sockets: [box.url("missing.sock")]).run(gateway: gateway(), now: .now)
    #expect(runner.calls.isEmpty)
    #expect(result.bytesFreed == 0 && result.errors.isEmpty)
  }

  @Test func stoppedDaemonRunsNoPrune() {
    let runner = FakeRunner(infoStatus: 1)
    let result = rule(runner).run(gateway: gateway(), now: .now)
    #expect(runner.calls == ["/info"])
    #expect(result.bytesFreed == 0 && result.errors.isEmpty)
  }

  @Test func runsExactlyTwoPrunes() {
    let runner = FakeRunner()
    let result = rule(runner).run(gateway: gateway(), now: .now)
    #expect(runner.calls == ["/info", "/build/prune", "/images/prune"])
    #expect(result.bytesFreed == 1_201_000_000)
    #expect(result.errors.isEmpty)
  }

  @Test func neverTouchesVolumesOrTaggedImages() {
    let runner = FakeRunner()
    _ = rule(runner).run(gateway: gateway(), now: .now)
    let request = runner.invocations.flatMap(\.arguments).joined(separator: " ")
    for banned in ["/volumes", "/system", "/containers", "all=", "dangling=false"] { #expect(!request.contains(banned)) }
  }

  @Test func externalDataFolderSkips() throws {
    try settings(#"{"DataFolder": "/Volumes/Ext/Docker"}"#)
    let runner = FakeRunner()
    _ = rule(runner, onBoot: false).run(gateway: gateway(), now: .now)
    #expect(runner.calls == ["/info"])
  }

  @Test func defaultLocationOffBootVolumeSkips() {
    let runner = FakeRunner()
    _ = rule(runner, onBoot: false).run(gateway: gateway(), now: .now)
    #expect(runner.calls == ["/info"])
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
    #expect(runner.calls == ["/info"])
  }

  @Test func unparseableSettingsTouchNothing() throws {
    try settings("{not json")
    let runner = FakeRunner()
    let result = rule(runner).run(gateway: gateway(), now: .now)
    #expect(runner.calls == ["/info"])
    #expect(result.bytesFreed == 0)
  }

  @Test func unreadableSettingsFolderTouchesNothing() throws {
    try settings(#"{"DataFolder": "/Volumes/Ext/Docker"}"#)
    let dir = box.url("Library/Group Containers/group.com.docker").path(percentEncoded: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir) }
    let runner = FakeRunner()
    _ = rule(runner, onBoot: false).run(gateway: gateway(), now: .now)
    #expect(runner.calls == ["/info"])
  }

  @Test func nonStringDataFolderTouchesNothing() throws {
    try settings(#"{"DataFolder": 5}"#)
    let runner = FakeRunner()
    _ = rule(runner).run(gateway: gateway(), now: .now)
    #expect(runner.calls == ["/info"])
  }

  @Test func pruneFailureIsAnError() {
    let runner = FakeRunner(pruneStatus: 1)
    let result = rule(runner).run(gateway: gateway(), now: .now)
    #expect(!result.errors.isEmpty)
  }

  @Test func dryRunLaunchesNothing() {
    let runner = FakeRunner()
    _ = rule(runner, mode: .dryRun).run(gateway: gateway(), now: .now)
    #expect(runner.calls.isEmpty)
  }

  // No docker program or plugin runs: only Apple's curl, which skips ~/.curlrc (--disable must come first).
  @Test func talksToTheSocketThroughAppleCurlOnly() {
    let runner = FakeRunner()
    _ = rule(runner).run(gateway: gateway(), now: .now)
    #expect(runner.invocations.count == 3)
    for call in runner.invocations {
      #expect(call.executable == URL(filePath: "/usr/bin/curl"))
      #expect(call.arguments.first == "--disable")
      #expect(call.arguments.contains(socket.path(percentEncoded: false)))
    }
  }

  @Test func staleFirstSocketFallsThroughToTheNext() {
    let dead = box.file("dead.sock").path(percentEncoded: false)
    let live = box.file("live.sock")
    let runner = FakeRunner(infoStatusFor: { $0 == dead ? 7 : 0 })
    _ = rule(runner, sockets: [URL(filePath: dead), live]).run(gateway: gateway(), now: .now)
    #expect(runner.calls == ["/info", "/info", "/build/prune", "/images/prune"])
    #expect(runner.invocations.suffix(2).allSatisfy { $0.arguments.contains(live.path(percentEncoded: false)) })
  }

  @Test func parsesReclaimed() {
    #expect(DockerRule.reclaimed(#"{"CachesDeleted":null,"SpaceReclaimed":1200000000}"#) == 1_200_000_000)
    #expect(DockerRule.reclaimed(#"{"SpaceReclaimed":0}"#) == 0)
    #expect(DockerRule.reclaimed("garbage") == 0)
    #expect(DockerRule.reclaimed(#"{"SpaceReclaimed":-5}"#) == 0)
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
