import Foundation

public enum Format {
  public static func bytes(_ n: Int64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    f.allowsNonnumericFormatting = false  // "0 bytes" instead of "Zero KB"
    return f.string(fromByteCount: n)
  }

  public static func percent(_ f: Double) -> String { "\(Int((f * 100).rounded()))%" }

  public static func menuBarText(freeBytes: Int64, memoryFraction: Double) -> String {
    "\(bytes(freeBytes)) · \(percent(memoryFraction))"
  }

  /// Sum of bytes freed by runs in the same calendar month as `now`.
  public static func monthlyTotal(_ history: [RunRecord], now: Date, calendar: Calendar) -> Int64 {
    history.filter { calendar.isDate($0.date, equalTo: now, toGranularity: .month) }
      .reduce(0) { $0 + $1.totalBytes }
  }
}
