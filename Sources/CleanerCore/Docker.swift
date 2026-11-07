import Foundation

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
  private let sockets: [URL]

  /// Docker Desktop's own socket, the system link to it, then Colima's.
  public static func defaultSockets(home: URL) -> [URL] {
    [home.appending(path: ".docker/run/docker.sock"), URL(filePath: "/var/run/docker.sock"),
     home.appending(path: ".colima/default/docker.sock")]
  }

  public init(home: URL, runner: any CommandRunner, mode: DeletionGateway.Mode,
              isOnBootVolume: @escaping @Sendable (URL) -> Bool, sockets: [URL]? = nil) {
    self.home = home
    self.runner = runner
    self.mode = mode
    self.isOnBootVolume = isOnBootVolume
    self.sockets = sockets ?? Self.defaultSockets(home: home)
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

  /// The Engine API through Apple's curl, so no docker program, plugin or helper runs: those sit in
  /// folders other apps can write, and a child of this app can share its Full Disk Access.
  /// `--disable` must come first: it skips ~/.curlrc.
  private func request(_ socket: URL, _ method: String, _ path: String, timeout: TimeInterval) -> (status: Int32, output: String)? {
    runner.run(URL(filePath: "/usr/bin/curl"),
               ["--disable", "--silent", "--show-error", "--fail", "--max-time", "\(Int(timeout))", "--max-filesize", "67108864", "-X", method,
                "--unix-socket", socket.path(percentEncoded: false), "http://localhost" + path],
               timeout: timeout + 5)
  }

  public func run(gateway: DeletionGateway, now: Date) -> CleanResult {
    var result = CleanResult(category: category, bytesFreed: 0, errors: [])
    // A dry run sends nothing: a prune is the only thing this rule does.
    if mode == .dryRun { return result }
    // Never starts Docker: a stopped daemon fails /info. A stale socket left by one engine falls through to the next.
    guard let socket = sockets.first(where: { socket in
      FileManager.default.fileExists(atPath: socket.path(percentEncoded: false))
        && request(socket, "GET", "/info", timeout: 10)?.status == 0
    }) else { return result }
    switch dataFolder() {
    case .unknown: return result
    case .custom(let url) where !isOnBootVolume(url): return result
    case .internalDefault where !isOnBootVolume(home): return result  // the default data folder sits under home
    default: break
    }
    // Defaults match `docker builder prune -f` and `docker image prune -f`: dangling only, never volumes or tagged images.
    for (name, path) in [("builder", "/build/prune"), ("image", "/images/prune")] {
      guard let out = request(socket, "POST", path, timeout: 120) else {
        result.errors.append("docker \(name) prune: request failed to run or timed out")
        continue
      }
      if out.status != 0 {
        result.errors.append("docker \(name) prune: request failed (curl exit \(out.status))")
      } else {
        result.bytesFreed += Self.reclaimed(out.output)
      }
    }
    return result
  }

  /// `SpaceReclaimed` from a prune response; 0 when missing or unreadable.
  public static func reclaimed(_ json: String) -> Int64 {
    struct Response: Decodable { var SpaceReclaimed: Int64? }
    let value = (try? JSONDecoder().decode(Response.self, from: Data(json.utf8)))?.SpaceReclaimed ?? 0
    // Capped at 1 PB: any process of this user can answer on that socket, and an overflowing sum would trap.
    return min(max(0, value), 1_000_000_000_000_000)
  }
}
