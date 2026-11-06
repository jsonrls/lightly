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
}

public struct RunRecord: Codable, Sendable, Equatable {
  public var date: Date
  public var manual: Bool
  public var results: [CleanResult]
  public var totalBytes: Int64 { results.reduce(0) { $0 + $1.bytesFreed } }
  public var hasErrors: Bool { results.contains { !$0.errors.isEmpty } }
}

public enum Limits {
  public static let day: TimeInterval = 86_400
  public static let logAge = 7 * day, trashAge = 30 * day, leftoverGrace = 30 * day
  public static let cacheIdle = 7 * day, derivedDataIdle = 7 * day, weekly = 7 * day
  public static let runHour = 3
}

// Enabled in Task 2 once DeletionGateway exists.
// public protocol CleanRule: Sendable {
//   var category: CleanCategory { get }
//   var weekly: Bool { get }
//   func run(gateway: DeletionGateway, now: Date) -> CleanResult
// }
