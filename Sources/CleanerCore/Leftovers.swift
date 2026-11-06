import Foundation

public struct AppInventory: Codable, Sendable, Equatable {
  public var installed: Set<String> = []
  public var removed: [String: Date] = [:]  // bundle ID -> date first seen missing
  public init() {}

  /// An empty `present` means the scan failed (unreadable folders), so nothing is learned from it.
  public mutating func update(present: Set<String>, now: Date) {
    guard !present.isEmpty else { return }
    for id in installed.subtracting(present) where removed[id] == nil { removed[id] = now }
    installed.formUnion(present)
    for id in present { removed[id] = nil }
  }

  public func due(now: Date) -> [String] {
    removed.filter { !$0.key.hasPrefix("com.apple.") && now.timeIntervalSince($0.value) >= Limits.leftoverGrace }
      .keys.sorted()
  }

  public mutating func resetClock(_ id: String, now: Date) { removed[id] = now }
  /// Also forgets the install, or the next `update` would date the app as missing again.
  public mutating func markCleaned(_ ids: [String]) {
    for id in ids {
      removed[id] = nil
      installed.remove(id)
    }
  }
}

public enum InstalledApps {
  /// Bundle IDs of `*.app` at depth 1 and 2. Linked apps are not counted (a link reports isDirectory false).
  /// An absent folder is skipped. A folder that exists but cannot be listed makes the whole scan empty,
  /// because a partial list would mark every app in it as gone.
  public static func scan(_ dirs: [URL]) -> Set<String> {
    let fm = FileManager.default
    var ids: Set<String> = []
    var failed = false
    func visit(_ dir: URL, depth: Int) {
      guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else {
        if fm.fileExists(atPath: dir.path(percentEncoded: false)) { failed = true }
        return
      }
      for item in items {
        guard (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
        if item.pathExtension == "app" {
          let plist = item.appending(path: "Contents/Info.plist")
          if let data = try? Data(contentsOf: plist),
             let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
             let id = info["CFBundleIdentifier"] as? String { ids.insert(id) }
        } else if depth < 2 {
          visit(item, depth: depth + 1)
        }
      }
    }
    for d in dirs { visit(d, depth: 1) }
    return failed ? [] : ids
  }
}

public struct LeftoverRule: CleanRule {
  public let category = CleanCategory.leftovers
  public let weekly = false
  private let libraryDir: URL
  private let bundleIDs: [String]

  public init(libraryDir: URL, bundleIDs: [String]) {
    self.libraryDir = libraryDir
    self.bundleIDs = bundleIDs
  }

  public static func candidates(libraryDir: URL, bundleID id: String) -> [URL] {
    guard id.wholeMatch(of: /[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+/) != nil else { return [] }
    return [
      "Application Support/\(id)", "Caches/\(id)", "Preferences/\(id).plist",
      "Saved Application State/\(id).savedState", "HTTPStorages/\(id)", "WebKit/\(id)", "Logs/\(id)",
    ].map { libraryDir.appending(path: $0) }
  }

  /// File dates only: cleaning a folder refreshes the folder's own date, and that is not use.
  /// Anything that cannot be read counts as recent.
  public static func recentlyUsed(libraryDir: URL, bundleID: String, now: Date) -> Bool {
    candidates(libraryDir: libraryDir, bundleID: bundleID).contains { candidate in
      guard exists(candidate) else { return false }
      return files(in: candidate)?.contains { now.timeIntervalSince($0.modified) < Limits.leftoverGrace } ?? true
    }
  }

  static let browserDataFiles: Set<String> = ["Login Data", "Cookies", "places.sqlite"]

  /// Saved logins and cookies are not leftovers, whatever the app's age. Anything that cannot be read counts as holding them.
  public static func holdsBrowserData(libraryDir: URL, bundleID: String) -> Bool {
    candidates(libraryDir: libraryDir, bundleID: bundleID).contains { candidate in
      guard exists(candidate) else { return false }
      return files(in: candidate)?.contains { browserDataFiles.contains($0.name) } ?? true
    }
  }

  /// Everything at or under `url` that is not a folder. Links are not followed. nil when anything cannot be read.
  private static func files(in url: URL) -> [(name: String, modified: Date)]? {
    var found: [(name: String, modified: Date)] = []
    var unreadable = false
    /// True for a folder.
    func visit(_ url: URL) -> Bool {
      // attributesOfItem uses lstat, so a link reports itself.
      guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)),
            let modified = attributes[.modificationDate] as? Date
      else {
        unreadable = true
        return false
      }
      if attributes[.type] as? FileAttributeType == .typeDirectory { return true }
      found.append((url.lastPathComponent, modified))
      return false
    }
    // The enumerator reports a plain file as an error, so only folders go through it.
    if visit(url) {
      guard let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, errorHandler: { _, _ in
        unreadable = true
        return true
      }) else { return nil }
      while let item = items.nextObject() as? URL { _ = visit(item) }
    }
    return unreadable ? nil : found
  }

  /// lstat, so a dangling link counts as present.
  static func exists(_ url: URL) -> Bool {
    (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))) != nil
  }

  public func run(gateway: DeletionGateway, now: Date) -> CleanResult {
    var result = CleanResult(category: category, bytesFreed: 0, errors: [])
    for id in bundleIDs where !Self.recentlyUsed(libraryDir: libraryDir, bundleID: id, now: now)
      && !Self.holdsBrowserData(libraryDir: libraryDir, bundleID: id) {
      for url in Self.candidates(libraryDir: libraryDir, bundleID: id)
      where Self.exists(url) {
        result.record(url) { try gateway.trash($0) }
      }
    }
    return result
  }
}
