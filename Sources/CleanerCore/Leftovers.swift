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
  public mutating func markCleaned(_ ids: [String]) { for id in ids { removed[id] = nil } }
}

public enum InstalledApps {
  /// Bundle IDs of `*.app` at depth 1 and 2. Symlinks are skipped; unreadable folders yield what was found.
  public static func scan(_ dirs: [URL]) -> Set<String> {
    let fm = FileManager.default
    var ids: Set<String> = []
    func visit(_ dir: URL, depth: Int) {
      guard let items = try? fm.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey]) else { return }
      for item in items {
        let v = try? item.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard v?.isSymbolicLink != true, v?.isDirectory == true else { continue }
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
    return ids
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
    guard id.wholeMatch(of: /[A-Za-z0-9.-]+/) != nil, !id.contains("..") else { return [] }
    return [
      "Application Support/\(id)", "Caches/\(id)", "Preferences/\(id).plist",
      "Saved Application State/\(id).savedState", "HTTPStorages/\(id)", "WebKit/\(id)", "Logs/\(id)",
    ].map { libraryDir.appending(path: $0) }
  }

  public static func recentlyUsed(libraryDir: URL, bundleID: String, now: Date) -> Bool {
    candidates(libraryDir: libraryDir, bundleID: bundleID).contains {
      now.timeIntervalSince(newestModification(in: $0)) < Limits.leftoverGrace
    }
  }

  public func run(gateway: DeletionGateway, now: Date) -> CleanResult {
    var result = CleanResult(category: category, bytesFreed: 0, errors: [])
    for id in bundleIDs where !Self.recentlyUsed(libraryDir: libraryDir, bundleID: id, now: now) {
      for url in Self.candidates(libraryDir: libraryDir, bundleID: id)
      where (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))) != nil {
        result.record(url) { try gateway.trash($0) }
      }
    }
    return result
  }
}
