import Foundation
import Security

public protocol CommandRunner: Sendable {
  /// nil on launch failure or timeout.
  func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) -> (status: Int32, output: String)?
}

public struct ProcessRunner: CommandRunner {
  public init() {}

  public func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) -> (status: Int32, output: String)? {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    // One pipe for stdout and stderr, drained as it arrives so a chatty child never blocks on a full pipe.
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    process.standardInput = FileHandle.nullDevice
    let buffer = LockedData()
    let drained = DispatchSemaphore(value: 0)
    pipe.fileHandleForReading.readabilityHandler = { handle in
      let chunk = handle.availableData
      if chunk.isEmpty {
        handle.readabilityHandler = nil
        drained.signal()
      } else { buffer.append(chunk) }
    }
    let done = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in done.signal() }
    do { try process.run() } catch {
      pipe.fileHandleForReading.readabilityHandler = nil
      return nil
    }
    if done.wait(timeout: .now() + timeout) == .timedOut {
      process.terminate()
      if done.wait(timeout: .now() + 2) == .timedOut { kill(process.processIdentifier, SIGKILL) }
      pipe.fileHandleForReading.readabilityHandler = nil
      return nil
    }
    // Wait for the handler to see end of output, so the last chunk is not lost. Bounded: a grandchild
    // that inherited the pipe can keep it open long after the child exits.
    _ = drained.wait(timeout: .now() + 1)
    pipe.fileHandleForReading.readabilityHandler = nil
    return (process.terminationStatus, String(decoding: buffer.data, as: UTF8.self))
  }
}

private final class LockedData: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = Data()
  func append(_ data: Data) { lock.withLock { storage.append(data) } }
  var data: Data { lock.withLock { storage } }
}

public struct DockerRule: CleanRule {
  public let category = CleanCategory.docker
  public let weekly = true
  private let home: URL
  private let runner: any CommandRunner
  private let mode: DeletionGateway.Mode
  private let isOnBootVolume: @Sendable (URL) -> Bool
  private let candidates: [URL]
  private let isTrusted: @Sendable (URL) -> Bool

  public static let defaultCandidates: [URL] = [
    "/usr/local/bin/docker", "/opt/homebrew/bin/docker", "/Applications/Docker.app/Contents/Resources/bin/docker",
  ].map { URL(filePath: $0) }

  public init(home: URL, runner: any CommandRunner, mode: DeletionGateway.Mode,
              isOnBootVolume: @escaping @Sendable (URL) -> Bool,
              candidates: [URL] = DockerRule.defaultCandidates,
              isTrusted: @escaping @Sendable (URL) -> Bool = DockerRule.isDockerSigned) {
    self.home = home
    self.runner = runner
    self.mode = mode
    self.isOnBootVolume = isOnBootVolume
    self.candidates = candidates
    self.isTrusted = isTrusted
  }

  /// The candidate folders are writable by the owner, and a child may share the app's Full Disk Access,
  /// so only Docker Inc's own signed binary is run.
  // shortcut: a Homebrew-built docker is unsigned and is skipped; check-then-exec leaves a short swap window.
  public static func isDockerSigned(_ url: URL) -> Bool {
    var code: SecStaticCode?
    var requirement: SecRequirement?
    let docker = "anchor apple generic and certificate leaf[subject.OU] = \"9BNSXJN65R\"" as CFString
    guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
          SecRequirementCreateWithString(docker, [], &requirement) == errSecSuccess
    else { return false }
    return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement) == errSecSuccess
  }

  /// Result of reading Docker Desktop's settings: unknown means the rule must not touch Docker.
  private enum DataFolder { case internalDefault, custom(URL), unknown }

  private func dataFolder() -> DataFolder {
    let dir = home.appending(path: "Library/Group Containers/group.com.docker")
    for name in ["settings-store.json", "settings.json"] {
      let data: Data
      do { data = try Data(contentsOf: dir.appending(path: name)) }
      catch let error as CocoaError where error.code == .fileReadNoSuchFile { continue }
      catch { return .unknown }  // unreadable is not absent
      guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .unknown }
      if let value = json["DataFolder"] ?? json["dataFolder"] {
        guard let path = value as? String, !path.isEmpty else { return .unknown }
        return .custom(URL(filePath: path, directoryHint: .isDirectory))
      }
    }
    return .internalDefault
  }

  public func run(gateway: DeletionGateway, now: Date) -> CleanResult {
    var result = CleanResult(category: category, bytesFreed: 0, errors: [])
    // A dry run launches nothing: running third-party code is itself a side effect.
    if mode == .dryRun { return result }
    // Resolved first, so the file that was checked is the file that runs.
    guard let docker = candidates.map({ $0.resolvingSymlinksInPath() })
      .first(where: { FileManager.default.isExecutableFile(atPath: $0.path(percentEncoded: false)) }),
      isTrusted(docker)
    else { return result }
    // Never launches Docker: a stopped daemon makes `info` fail and we stop.
    guard let info = runner.run(docker, ["info"], timeout: 10), info.status == 0 else { return result }
    switch dataFolder() {
    case .unknown: return result
    case .custom(let url) where !isOnBootVolume(url): return result
    case .internalDefault where !isOnBootVolume(home): return result  // the default data folder sits under home
    default: break
    }
    for arguments in [["builder", "prune", "-f"], ["image", "prune", "-f"]] {
      guard let out = runner.run(docker, arguments, timeout: 120) else {
        result.errors.append("docker \(arguments[0]) prune: failed to run or timed out")
        continue
      }
      if out.status != 0 {
        result.errors.append("docker \(arguments[0]) prune: exit \(out.status)")
      } else {
        result.bytesFreed += Self.parseReclaimed(out.output)
      }
    }
    return result
  }

  public static func parseReclaimed(_ output: String) -> Int64 {
    // Classic prune prints "Total reclaimed space: X"; buildx (builder prune) prints "Total:\tX".
    var rest: Substring?
    for line in output.split(whereSeparator: \.isNewline) {
      for marker in ["Total reclaimed space:", "Total:"] where line.hasPrefix(marker) { rest = line.dropFirst(marker.count) }
    }
    guard let token = rest?.split(whereSeparator: { $0 == " " || $0 == "\t" }).first else { return 0 }
    let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("B", 1)]
    guard let (suffix, factor) = units.first(where: { token.hasSuffix($0.0) }),
          let value = Double(token.dropLast(suffix.count))
    else { return 0 }
    return Int64((value * factor).rounded())
  }
}
