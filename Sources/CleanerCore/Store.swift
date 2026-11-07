import Foundation

public struct DiskSample: Codable, Sendable, Equatable {
  public var day: Date
  public var freeBytes: Int64
  public init(day: Date, freeBytes: Int64) {
    self.day = day
    self.freeBytes = freeBytes
  }
}

/// What the owner chose in the settings window.
public struct CleanSettings: Codable, Sendable, Equatable {
  public static let intervalChoices = [1, 3, 6, 12, 24]

  public var openAtLogin = true
  public var useAppleIntelligence = true
  public var intervalHours = 1
  public var disabled: Set<CleanCategory> = []
  public var keptFolders: [String] = []

  public init() {}

  /// Field by field, so one missing or unknown value falls back to its default instead of failing the whole state.
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    openAtLogin = (try? values.decode(Bool.self, forKey: .openAtLogin)) ?? openAtLogin
    useAppleIntelligence = (try? values.decode(Bool.self, forKey: .useAppleIntelligence)) ?? useAppleIntelligence
    // A value the picker cannot show would leave it blank while cleaning ran on that hidden value.
    if let hours = try? values.decode(Int.self, forKey: .intervalHours), Self.intervalChoices.contains(hours) { intervalHours = hours }
    // These two only ever narrow deletion, so a fallback would widen it. Unknown category names are
    // dropped and the rest kept; a damaged list fails the whole state, which then starts paused.
    if values.contains(.disabled) {
      disabled = Set(try values.decode([String].self, forKey: .disabled).compactMap(CleanCategory.init(rawValue:)))
    }
    if values.contains(.keptFolders) { keptFolders = try values.decode([String].self, forKey: .keptFolders) }
  }

  /// Never under an hour, so a damaged value cannot clean in a loop.
  public var interval: TimeInterval { TimeInterval(max(1, intervalHours)) * 3600 }
}

public struct AppState: Codable, Sendable, Equatable {
  public var history: [RunRecord] = []
  public var inventory = AppInventory()
  public var diskSamples: [DiskSample] = []
  public var paused = false
  public var lastScheduledRun: Date?
  public var lastWeeklyRun: Date?
  // Optional: a required key would make every state.json written before settings existed read as corrupt.
  var storedSettings: CleanSettings?
  public init() {}

  public var settings: CleanSettings {
    get { storedSettings ?? CleanSettings() }
    set { storedSettings = newValue }
  }

  public mutating func prune(now: Date) {
    history.removeAll { $0.date < now - 365 * Limits.day }
    diskSamples.removeAll { $0.day < now - 30 * Limits.day }
  }
}

public struct Store: Sendable {
  let directory: URL
  public init(directory: URL) { self.directory = directory }

  private enum Folder { case missing, unsafe, open(Int32) }

  /// The folder as a descriptor, refused if any part of its path is a link or it is not ours: every read,
  /// write and rename goes through it, so a folder swapped for a link cannot send them elsewhere.
  private func folder() -> Folder {
    let fd = directory.withUnsafeFileSystemRepresentation { path in
      path.map { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY) } ?? -1
    }
    guard fd >= 0 else { return errno == ENOENT ? .missing : .unsafe }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_uid == getuid() else {
      close(fd)
      return .unsafe
    }
    return .open(fd)
  }

  /// Missing file is a fresh install. A file that exists but cannot be read or decoded is moved to
  /// state.corrupt.json and the app starts paused, so a lost pause never turns into a surprise clean.
  /// An unsafe folder is left untouched and also starts paused.
  public func load() -> AppState {
    guard case .open(let dir) = folder() else { return peek() }
    defer { close(dir) }
    if let state = read(in: dir) { return state }
    // renameat, not FileManager: it replaces an older aside atomically, and deletion is reserved for DeletionGateway.
    _ = renameat(dir, "state.json", dir, "state.corrupt.json")  // on failure we still start paused
    return Self.pausedState
  }

  /// Same result as `load()` but changes nothing on disk, so a dry run cannot move a corrupt file
  /// away and leave the next live launch unpaused.
  public func peek() -> AppState {
    switch folder() {
    case .missing: return AppState()
    case .unsafe: return Self.pausedState
    case .open(let dir):
      defer { close(dir) }
      return read(in: dir) ?? Self.pausedState
    }
  }

  /// Nil when the file exists but cannot be read or decoded. Non-blocking and regular files only,
  /// so a planted FIFO or device cannot hang the launch.
  private func read(in dir: Int32) -> AppState? {
    let fd = openat(dir, "state.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    if fd < 0 { return errno == ENOENT ? AppState() : nil }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, let data = try? handle.readToEnd() else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(AppState.self, from: data)
  }

  /// Writes `name` in the state folder atomically: a new file, then a rename over the old one.
  public func write(_ data: Data, named name: String) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    guard case .open(let dir) = folder() else { throw CocoaError(.fileWriteNoPermission) }
    defer { close(dir) }
    let temp = ".\(name).\(UUID().uuidString)"
    let fd = openat(dir, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    do {
      try FileHandle(fileDescriptor: fd, closeOnDealloc: true).write(contentsOf: data)
      guard renameat(dir, temp, dir, name) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    } catch {
      unlinkat(dir, temp, 0)
      throw error
    }
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
    try write(encoder.encode(state), named: "state.json")
  }

  public static func defaultDirectory() -> URL {
    CleanEnvironment.userHome.appending(path: "Library/Application Support/com.maccleaner.app", directoryHint: .isDirectory)
  }
}
