import Foundation

public enum CleanCategory: String, Codable, CaseIterable, Sendable {
  case appCaches, logs, trash, leftovers, devCaches, docker
  public var displayName: String {
    switch self {
    case .appCaches: "App caches"
    case .logs: "Logs"
    case .trash: "Trash (30+ days)"
    case .leftovers: "App leftovers"
    case .devCaches: "Developer caches"
    case .docker: "Docker build cache"
    }
  }
}

public struct CleanResult: Codable, Sendable, Equatable {
  public var category: CleanCategory
  public var bytesFreed: Int64
  public var errors: [String]
  public init(category: CleanCategory, bytesFreed: Int64, errors: [String]) {
    self.category = category
    self.bytesFreed = bytesFreed
    self.errors = errors
  }

  /// Runs `op`. `.symlink`, `.notOnBootVolume` and `.kept` are silent skips; any other error is appended as "<name>: <message>".
  /// `hidingName` replaces both with `label`, since an error's message can repeat the name.
  public mutating func record(_ url: URL, hidingName label: String? = nil, _ op: (URL) throws -> Int64) {
    do {
      bytesFreed += try op(url)
    } catch DeletionGateway.Refusal.symlink, DeletionGateway.Refusal.notOnBootVolume, DeletionGateway.Refusal.kept {
    } catch {
      errors.append(label.map { "\($0): could not be deleted" } ?? "\(url.lastPathComponent): \(error.localizedDescription)")
    }
  }
}

public struct RunRecord: Codable, Sendable, Equatable {
  public var date: Date
  public var manual: Bool
  public var results: [CleanResult]
  public init(date: Date, manual: Bool, results: [CleanResult]) {
    self.date = date
    self.manual = manual
    self.results = results
  }
  public var totalBytes: Int64 { results.reduce(0) { $0 + $1.bytesFreed } }
  public var hasErrors: Bool { results.contains { !$0.errors.isEmpty } }
}

public enum Limits {
  public static let day: TimeInterval = 86_400
  public static let logAge = 7 * day, trashAge = 30 * day, leftoverGrace = 30 * day
  public static let cacheIdle = 7 * day, derivedDataIdle = 7 * day, weekly = 7 * day
}

public protocol CleanRule: Sendable {
  var category: CleanCategory { get }
  var weekly: Bool { get }
  func run(gateway: DeletionGateway, now: Date) -> CleanResult
}
