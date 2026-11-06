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

  /// Missing or unreadable state is empty state, and an empty state never triggers a run (see `Scheduler.shouldRun`).
  public func load() -> AppState {
    guard let data = try? Data(contentsOf: file) else { return AppState() }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return (try? decoder.decode(AppState.self, from: data)) ?? AppState()
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
