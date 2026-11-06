import Foundation

/// What the on-device model is told about a run, and the check on what it says back.
/// The model only describes a finished run: it never decides what gets deleted.
public enum CleanBrief {
  /// Category totals only, never the path list: the model's context is small.
  public static func facts(_ record: RunRecord) -> String {
    let freed = record.results.filter { $0.bytesFreed > 0 }.sorted { $0.bytesFreed > $1.bytesFreed }
    var lines = ["Total freed: \(Format.bytes(record.totalBytes))"]
    for (index, result) in freed.enumerated() {
      let name = result.category.displayName
      let bytes = Format.bytes(result.bytesFreed)
      lines.append(index == 0 ? "Biggest: \(name), \(bytes)" : "\(name): \(bytes)")
    }
    let errors = record.results.flatMap(\.errors)
    lines += errors.prefix(3).map { "Error: \($0.prefix(200))" }
    if errors.count > 3 { lines.append("More errors: \(errors.count - 3)") }
    return lines.joined(separator: "\n")
  }

  /// The model compares figures badly, so it must name the true biggest category and state only given numbers.
  public static func isFaithful(_ text: String, to record: RunRecord) -> Bool {
    let stated = numbers(in: text)
    let total = numbers(in: Format.bytes(record.totalBytes))
    guard Set(stated).isSubset(of: numbers(in: facts(record))), Set(total).isSubset(of: stated) else { return false }
    return biggest(record).map { text.localizedCaseInsensitiveContains($0.category.displayName) } ?? false  // an empty run has no story to tell
  }

  /// The model copies names from its examples, so it must name the folder that really failed.
  public static func isFaithfulProblem(_ text: String, to record: RunRecord) -> Bool {
    guard let name = failedItem(record), text.localizedCaseInsensitiveContains(name) else { return false }
    return Set(numbers(in: text)).isSubset(of: numbers(in: facts(record)))
  }

  public static func fallbackProblem(_ record: RunRecord) -> String {
    "\(failedItem(record) ?? "One item") could not be removed this time and will be tried again later."
  }

  /// Errors from the gateway read "<name>: <message>"; others name nothing.
  private static func failedItem(_ record: RunRecord) -> String? {
    guard let error = record.results.flatMap(\.errors).first, let colon = error.firstIndex(of: ":") else { return nil }
    return String(error[..<colon])
  }

  public static func fallbackHeadline(_ record: RunRecord) -> String {
    guard let biggest = biggest(record) else { return "Nothing needed cleaning." }
    return "Freed \(Format.bytes(record.totalBytes)), mostly from \(biggest.category.displayName)."
  }

  private static func biggest(_ record: RunRecord) -> CleanResult? {
    record.results.filter { $0.bytesFreed > 0 }.max { $0.bytesFreed < $1.bytesFreed }
  }

  static func numbers(in text: String) -> [String] {
    text.matches(of: /\d+(?:\.\d+)?/).map { String($0.output) }
  }
}
