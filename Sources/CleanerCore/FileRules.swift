import Foundation

/// Newest modification date of the folder and everything under it. Links are not followed.
/// Anything that cannot be read gives `.distantFuture`, so callers treat the folder as in use.
func newestModification(in url: URL) -> Date {
  var unreadable = false
  func modified(_ url: URL) -> Date {
    // attributesOfItem uses lstat, so a link reports itself.
    guard let date = (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)))?[.modificationDate] as? Date
    else {
      unreadable = true
      return .distantPast
    }
    return date
  }
  var newest = modified(url)
  // The enumerator reports a plain file as an error, so only folders go through it.
  let isFolder = (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)))?[.type] as? FileAttributeType == .typeDirectory
  let items = isFolder ? FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) { _, _ in
    unreadable = true
    return true
  } : nil
  while let item = items?.nextObject() as? URL { newest = max(newest, modified(item)) }
  return unreadable ? .distantFuture : newest
}

public struct CacheRule: CleanRule {
  public let category = CleanCategory.appCaches
  public let weekly = false
  private let cachesDir: URL
  private let runningBundleIDs: @Sendable () -> Set<String>
  private let installedBundleIDs: Set<String>

  public static let skipExact: Set<String> = [
    "CloudKit", "GeoServices", "PassKit", "FamilyCircle", "SiriEntityCache", "GameKit", "Animoji",
    "Cypress", "electron", "puppeteer", "org.webkit.Playwright",
    "Homebrew", "pip", "Yarn",  // DevCacheRule owns these
  ]
  public static let skipPrefixes = ["com.apple.", "ms-playwright"]

  public init(cachesDir: URL, runningBundleIDs: @escaping @Sendable () -> Set<String>, installedBundleIDs: Set<String>) {
    self.cachesDir = cachesDir
    self.runningBundleIDs = runningBundleIDs
    self.installedBundleIDs = installedBundleIDs
  }

  public func run(gateway: DeletionGateway, now: Date) -> CleanResult {
    var result = CleanResult(category: category, bytesFreed: 0, errors: [])
    guard let entries = try? FileManager.default.contentsOfDirectory(at: cachesDir, includingPropertiesForKeys: nil)
    else { return result }
    let running = runningBundleIDs()
    for entry in entries {
      let name = entry.lastPathComponent
      if Self.skipExact.contains(name) || Self.skipPrefixes.contains(where: name.hasPrefix) { continue }
      if running.contains(where: { name == $0 || name.hasPrefix($0 + ".") }) { continue }
      if !installedBundleIDs.contains(name),
         now.timeIntervalSince(newestModification(in: entry)) < Limits.cacheIdle { continue }
      result.record(entry) { try gateway.delete($0) }
    }
    return result
  }
}

public struct LogRule: CleanRule {
  public let category = CleanCategory.logs
  public let weekly = false
  private let logsDir: URL

  public init(logsDir: URL) { self.logsDir = logsDir }

  public func run(gateway: DeletionGateway, now: Date) -> CleanResult {
    var result = CleanResult(category: category, bytesFreed: 0, errors: [])
    let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
    guard let items = FileManager.default.enumerator(at: logsDir, includingPropertiesForKeys: keys) else { return result }
    for case let item as URL in items {
      // Crash reports stay: the owner may want them.
      if items.level == 1, item.lastPathComponent == "DiagnosticReports" { items.skipDescendants(); continue }
      guard let values = try? item.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
            let date = values.contentModificationDate, now.timeIntervalSince(date) >= Limits.logAge
      else { continue }
      result.record(item) { try gateway.delete($0) }
    }
    return result
  }
}

public struct TrashRule: CleanRule {
  public let category = CleanCategory.trash
  public let weekly = false
  private let trashDir: URL
  private let dateAdded: @Sendable (URL) -> Date?

  public static let systemDateAdded: @Sendable (URL) -> Date? = { url in
    try? url.resourceValues(forKeys: [.addedToDirectoryDateKey]).addedToDirectoryDate
  }

  public init(trashDir: URL, dateAdded: @escaping @Sendable (URL) -> Date? = TrashRule.systemDateAdded) {
    self.trashDir = trashDir
    self.dateAdded = dateAdded
  }

  /// False when the folder cannot be listed, for example without Full Disk Access.
  public static func hasAccess(trashDir: URL) -> Bool {
    (try? FileManager.default.contentsOfDirectory(atPath: trashDir.path(percentEncoded: false))) != nil
  }

  public func run(gateway: DeletionGateway, now: Date) -> CleanResult {
    var result = CleanResult(category: category, bytesFreed: 0, errors: [])
    // Hidden entries stay: .DS_Store holds Finder's "Put Back" locations.
    guard let entries = try? FileManager.default.contentsOfDirectory(at: trashDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
    else { return result }
    for entry in entries {
      guard let added = dateAdded(entry), now.timeIntervalSince(added) >= Limits.trashAge else { continue }
      result.record(entry) { try gateway.delete($0) }
    }
    return result
  }
}
