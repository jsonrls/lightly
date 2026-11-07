import Foundation

public struct FolderSize: Sendable, Equatable {
  public let name: String
  public let bytes: Int64
  public init(name: String, bytes: Int64) {
    self.name = name
    self.bytes = bytes
  }
}

public enum DiskUsage {
  /// Private folders are left out without Full Disk Access, so asking a question never raises a privacy prompt.
  public static func folders(home: URL, fullAccess: Bool) -> [(name: String, url: URL)] {
    let library = home.appending(path: "Library")
    var folders: [(name: String, url: URL)] = [
      ("Applications", URL(filePath: "/Applications")),
      ("App data", library.appending(path: "Application Support")),
      ("App caches", library.appending(path: "Caches")),
      ("Developer tools", library.appending(path: "Developer")),
      ("Logs", library.appending(path: "Logs")),
      ("npm cache", home.appending(path: ".npm")),
    ]
    if fullAccess {
      folders += ["Documents", "Desktop", "Downloads", "Movies", "Music", "Pictures"].map { ($0, home.appending(path: $0)) }
      folders += [("App containers", library.appending(path: "Containers")), ("Trash", home.appending(path: ".Trash"))]
    }
    return folders
  }

  /// Biggest first. A missing folder or a link is skipped, so nothing outside these folders is counted.
  public static func measure(_ folders: [(name: String, url: URL)]) -> [FolderSize] {
    folders.compactMap { folder in
      let isLink = (try? folder.url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink
      return isLink == false ? FolderSize(name: folder.name, bytes: DeletionGateway.size(of: folder.url)) : nil
    }
    .sorted { $0.bytes > $1.bytes }
  }

  /// Sizes each location from what is inside it, so one walk also finds the biggest items. Read-only.
  public static func scan(_ folders: [(name: String, url: URL)], limit: Int = 12) -> (folders: [FolderSize], largest: [FolderSize]) {
    var totals: [FolderSize] = []
    var items: [FolderSize] = []
    for folder in folders {
      let isLink = (try? folder.url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink
      guard isLink == false,
            let children = try? FileManager.default.contentsOfDirectory(at: folder.url, includingPropertiesForKeys: nil) else { continue }
      let inside = measure(children.map { (name: "\(folder.name): \($0.lastPathComponent)", url: $0) })
      totals.append(FolderSize(name: folder.name, bytes: inside.reduce(0) { $0 + $1.bytes }))
      items += inside
    }
    return (totals.sorted { $0.bytes > $1.bytes }, Array(items.sorted { $0.bytes > $1.bytes }.prefix(limit)))
  }
}

/// What the on-device model is told when asked a question, and the check on its answer.
/// It gets measured facts and no tools, so it can only reword them: it cannot act on anything.
public enum AskBrief {
  public struct Snapshot: Sendable {
    let stats: StatsSnapshot
    let folders: [FolderSize]
    let lastClean: String?
    let monthFreed: Int64
    let paused: Bool
    let fullAccess: Bool
    let intervalHours: Int
    var largest: [FolderSize]

    public init(stats: StatsSnapshot, folders: [FolderSize], largest: [FolderSize] = [], lastClean: String?, monthFreed: Int64, paused: Bool, fullAccess: Bool, intervalHours: Int = 3) {
      self.intervalHours = intervalHours
      self.largest = largest
      self.stats = stats
      self.folders = folders
      self.lastClean = lastClean
      self.monthFreed = monthFreed
      self.paused = paused
      self.fullAccess = fullAccess
    }
  }

  public static func facts(_ snapshot: Snapshot) -> String {
    let stats = snapshot.stats
    let used = stats.diskTotalBytes > 0 ? 1 - Double(stats.diskFreeBytes) / Double(stats.diskTotalBytes) : 0
    var lines = [
      "Disk: \(Format.bytes(stats.diskFreeBytes)) free of \(Format.bytes(stats.diskTotalBytes)), \(Format.percent(used)) used",
      "Memory: \(Format.percent(stats.memoryUsedFraction)) used",
      "CPU: \(Format.percent(stats.cpuFraction)) in use",
    ]
    if let battery = stats.batteryFraction { lines.append("Battery: \(Format.percent(battery))") }
    if !snapshot.folders.isEmpty { lines.append("Largest folders, biggest first:") }
    lines += snapshot.folders.map { "\($0.name): \(Format.bytes($0.bytes))" }
    if !snapshot.largest.isEmpty { lines.append("Largest items inside those folders, biggest first:") }
    lines += snapshot.largest.map { "\($0.name): \(Format.bytes($0.bytes))" }
    if !snapshot.fullAccess { lines.append("Not measured: Documents, Desktop, Downloads, Movies, Music, Pictures, Trash") }
    if let lastClean = snapshot.lastClean { lines.append("Last clean: \(lastClean)") }
    lines.append("Freed this month: \(Format.bytes(snapshot.monthFreed))")
    lines.append(snapshot.paused ? "Auto-clean: paused" : "Auto-clean: runs by itself every \(snapshot.intervalHours) hours")
    return lines.joined(separator: "\n")
  }

  /// Rejects a figure that was not measured, and any advice to delete: the model cannot judge what is safe to lose.
  public static func isSafe(_ answer: String, facts: String, question: String) -> Bool {
    let known = Set(CleanBrief.numbers(in: facts) + CleanBrief.numbers(in: question))
    return Set(CleanBrief.numbers(in: answer)).isSubset(of: known)
      && answer.firstMatch(of: /(?i)\b(delete|deleting|remove|removing|erase|erasing|uninstall|uninstalling|wipe|wiping|empty|emptying)\b/) == nil
  }

  /// A scan answer must name the three largest items in order: the model states real figures but ranks them badly.
  public static func ranksCorrectly(_ answer: String, _ snapshot: Snapshot) -> Bool {
    var rest = Substring(answer)
    for item in snapshot.largest.prefix(3) {
      let name = item.name.components(separatedBy: ": ").last ?? item.name
      guard let found = rest.range(of: name, options: .caseInsensitive) else { return false }
      rest = rest[found.upperBound...]
    }
    return true
  }

  public static func fallback(_ snapshot: Snapshot) -> String {
    let free = "Your disk has \(Format.bytes(snapshot.stats.diskFreeBytes)) free."
    let items = snapshot.largest.isEmpty ? snapshot.folders : snapshot.largest
    let biggest = items.prefix(3).map { "\($0.name) \(Format.bytes($0.bytes))" }.joined(separator: ", ")
    return biggest.isEmpty ? free : "\(free) The biggest things I measured: \(biggest)."
  }
}
