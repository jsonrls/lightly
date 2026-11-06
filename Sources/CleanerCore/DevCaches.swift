import Foundation

public struct DevCacheRule: CleanRule {
  public let category = CleanCategory.devCaches
  public let weekly = true
  private let home: URL
  private let environment: [String: String]

  public init(home: URL, environment: [String: String] = ProcessInfo.processInfo.environment) {
    self.home = home
    self.environment = environment
  }

  public static func derivedDataDir(home: URL) -> URL {
    home.appending(path: "Library/Developer/Xcode/DerivedData", directoryHint: .isDirectory)
  }

  public static func wholeCacheDirs(home: URL, environment: [String: String]) -> [URL] {
    let npm = npmCache(home: home, environment: environment)
    return [npm.appending(path: "_cacache", directoryHint: .isDirectory)]
      + ["Library/Caches/Yarn", "Library/pnpm/store", "Library/Caches/pip", "Library/Caches/Homebrew"]
        .map { home.appending(path: $0, directoryHint: .isDirectory) }
  }

  private static func npmCache(home: URL, environment: [String: String]) -> URL {
    func expand(_ path: String) -> URL {
      path.hasPrefix("~/") ? home.appending(path: String(path.dropFirst(2))) : URL(filePath: path, directoryHint: .isDirectory)
    }
    if let path = environment["npm_config_cache"], !path.isEmpty { return expand(path) }
    if let rc = try? String(contentsOf: home.appending(path: ".npmrc"), encoding: .utf8) {
      for line in rc.split(whereSeparator: \.isNewline) {
        let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 2, parts[0] == "cache", !parts[1].isEmpty { return expand(parts[1]) }
      }
    }
    return home.appending(path: ".npm", directoryHint: .isDirectory)
  }

  public func run(gateway: DeletionGateway, now: Date) -> CleanResult {
    var result = CleanResult(category: category, bytesFreed: 0, errors: [])
    let fm = FileManager.default
    for dir in Self.wholeCacheDirs(home: home, environment: environment) {
      // A missing directory is not an error.
      for child in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
        result.record(child) { try gateway.delete($0) }
      }
    }
    for project in (try? fm.contentsOfDirectory(at: Self.derivedDataDir(home: home), includingPropertiesForKeys: nil)) ?? [] {
      // Unreadable gives .distantFuture, so the folder is kept.
      guard now.timeIntervalSince(newestModification(in: project)) >= Limits.derivedDataIdle else { continue }
      result.record(project) { try gateway.delete($0) }
    }
    return result
  }
}
