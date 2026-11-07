import Foundation
@testable import CleanerCore

/// A throwaway folder under the system temporary directory. The OS clears it, so tests do not.
struct Sandbox {
  let root: URL
  private var fm: FileManager { .default }

  init() {
    let dir = FileManager.default.temporaryDirectory.appending(path: "cleaner-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    // canonicalPathKey, not resolvingSymlinksInPath: that one strips /private and leaves the /var link.
    let path = try! dir.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath!
    root = URL(filePath: path, directoryHint: .isDirectory)
  }

  @discardableResult func file(_ path: String, bytes: Int = 1024, ageDays: Double = 0) -> URL {
    let u = url(path)
    makeParent(of: u)
    try! Data(count: bytes).write(to: u)
    age(u, days: ageDays)
    return u
  }

  @discardableResult func dir(_ path: String, ageDays: Double = 0) -> URL {
    let u = url(path)
    try! fm.createDirectory(at: u, withIntermediateDirectories: true)
    age(u, days: ageDays)
    return u
  }

  @discardableResult func link(_ path: String, to target: URL) -> URL {
    let u = url(path)
    makeParent(of: u)
    try! fm.createSymbolicLink(atPath: u.path(percentEncoded: false),
                               withDestinationPath: target.path(percentEncoded: false))
    return u
  }

  func url(_ path: String) -> URL { root.appending(path: path) }

  /// Uses lstat, so a dangling link still counts as existing.
  func exists(_ path: String) -> Bool {
    (try? fm.attributesOfItem(atPath: url(path).path(percentEncoded: false))) != nil
  }

  func tree() -> [String] {
    ((try? fm.subpathsOfDirectory(atPath: root.path(percentEncoded: false))) ?? []).sorted()
  }

  var hooks: DeletionGateway.Hooks {
    let root = root
    // A real delete or move, but never outside this sandbox, whatever the gateway decided.
    @Sendable func guardInside(_ url: URL) throws {
      guard url.path(percentEncoded: false).hasPrefix(root.path(percentEncoded: false)) else {
        throw CocoaError(.fileWriteNoPermission)
      }
    }
    return .init(
      volumeOf: { _ in URL(filePath: "/") },
      remove: { url in
        try guardInside(url)
        try FileManager.default.removeItem(at: url)
      },
      trash: { url in
        try guardInside(url)
        let trash = root.appending(path: "__trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        var dest = trash.appending(path: url.lastPathComponent)
        var n = 1
        while FileManager.default.fileExists(atPath: dest.path(percentEncoded: false)) {
          n += 1
          dest = trash.appending(path: "\(url.lastPathComponent) \(n)")
        }
        try FileManager.default.moveItem(at: url, to: dest)
      })
  }

  func gateway(roots: [String], denied: [String] = [], kept: [String] = [], mode: DeletionGateway.Mode = .live,
               hooks: DeletionGateway.Hooks? = nil) -> DeletionGateway {
    DeletionGateway(allowedRoots: roots.map(url), deniedRoots: denied.map(url), keptRoots: kept.map(url),
                    bootVolume: URL(filePath: "/"), mode: mode, hooks: hooks ?? self.hooks)
  }

  private func makeParent(of url: URL) {
    try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  }

  private func age(_ url: URL, days: Double) {
    let date = Date(timeIntervalSinceNow: -days * Limits.day)
    try! fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path(percentEncoded: false))
  }
}
