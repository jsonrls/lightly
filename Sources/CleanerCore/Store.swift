import Foundation

public struct DiskSample: Codable, Sendable, Equatable {
  public var day: Date
  public var freeBytes: Int64
  public init(day: Date, freeBytes: Int64) {
    self.day = day
    self.freeBytes = freeBytes
  }
}

public struct AppState: Codable, Sendable, Equatable {
  public var history: [RunRecord] = []
  public var inventory = AppInventory()
  public var diskSamples: [DiskSample] = []
  public var paused = false
  public var lastScheduledRun: Date?
  public var lastWeeklyRun: Date?
  public init() {}

  public mutating func prune(now: Date) {
    history.removeAll { $0.date < now - 365 * Limits.day }
    diskSamples.removeAll { $0.day < now - 30 * Limits.day }
  }
}

public struct Store: Sendable {
  let directory: URL
  public init(directory: URL) { self.directory = directory }

  private var file: URL { directory.appending(path: "state.json") }

  /// Missing file is a fresh install. A file that exists but cannot be read or decoded is moved to
  /// state.corrupt.json and the app starts paused, so a lost pause never turns into a surprise clean.
  public func load() -> AppState {
    if let state = read() { return state }
    let aside = directory.appending(path: "state.corrupt.json")
    // rename(2), not FileManager: it replaces an older aside atomically, and deletion is reserved for DeletionGateway.
    _ = rename(file.path(percentEncoded: false), aside.path(percentEncoded: false))  // on failure we still start paused
    return Self.pausedState
  }

  /// Same result as `load()` but changes nothing on disk, so a dry run cannot move a corrupt file
  /// away and leave the next live launch unpaused.
  public func peek() -> AppState { read() ?? Self.pausedState }

  /// Nil when the file exists but cannot be read or decoded.
  private func read() -> AppState? {
    let data: Data
    do { data = try Data(contentsOf: file) } catch let e as CocoaError where e.code == .fileReadNoSuchFile {
      return AppState()
    } catch { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(AppState.self, from: data)
  }

  private static var pausedState: AppState {
    var s = AppState()
    s.paused = true
    return s
  }

  public func save(_ state: AppState) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(state)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try data.write(to: file, options: .atomic)
  }

  public static func defaultDirectory() -> URL {
    URL.applicationSupportDirectory.appending(path: "com.maccleaner.app", directoryHint: .isDirectory)
  }
}
