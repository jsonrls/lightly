import Foundation

public enum Format {
  public static func bytes(_ n: Int64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    f.allowsNonnumericFormatting = false  // "0 bytes" instead of "Zero KB"
    return f.string(fromByteCount: n)
  }

  public static func percent(_ f: Double) -> String { "\(Int((f * 100).rounded()))%" }

  /// Stopwatch style, cut to tenths so 59.99 never reads as 60.0s.
  public static func elapsed(_ seconds: Double) -> String {
    let tenths = Int(seconds * 10)
    let clock = "\(tenths % 600 / 10).\(tenths % 10)s"
    return tenths < 600 ? clock : "\(tenths / 600)m \(clock)"
  }

  public static func menuBarText(freeBytes: Int64, memoryFraction: Double) -> String {
    "\(bytes(freeBytes)) · \(percent(memoryFraction))"
  }

  /// Sum of bytes freed by runs in the same calendar month as `now`.
  public static func monthlyTotal(_ history: [RunRecord], now: Date, calendar: Calendar) -> Int64 {
    history.filter { calendar.isDate($0.date, equalTo: now, toGranularity: .month) }
      .reduce(0) { $0 + $1.totalBytes }
  }

  /// One measured line about this month's cleaning. nil when no clean ran this month.
  public static func monthInsight(_ history: [RunRecord], now: Date, calendar: Calendar) -> String? {
    let runs = history.filter { calendar.isDate($0.date, equalTo: now, toGranularity: .month) }
    guard !runs.isEmpty else { return nil }
    let cleans = runs.count == 1 ? "1 clean" : "\(runs.count) cleans"
    let total = runs.reduce(0) { $0 + $1.totalBytes }
    guard total > 0 else { return "This month: \(cleans), nothing needed removing." }
    let byCategory = Dictionary(runs.flatMap(\.results).map { ($0.category, $0.bytesFreed) }, uniquingKeysWith: +)
    let top = byCategory.first { $0.value * 2 > total }?.key
    return "This month: \(bytes(total)) freed in \(cleans)\(top.map { ", mostly \($0.displayName)" } ?? "")."
  }
}
