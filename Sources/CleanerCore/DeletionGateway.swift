import Foundation

/// The only path to file deletion in the app. Everything it refuses stays on disk.
public final class DeletionGateway: @unchecked Sendable {
  public enum Mode: Sendable { case live, dryRun }
  public enum Refusal: Error, Equatable { case symlink, outsideAllowedRoots, denied, notOnBootVolume }

  public struct Hooks: Sendable {
    public var volumeOf: @Sendable (URL) -> URL?  // nil = unknown or not internal
    public var remove: @Sendable (URL) throws -> Void
    public var trash: @Sendable (URL) throws -> Void

    public static let live = Hooks(
      volumeOf: { url in
        let values = try? url.resourceValues(forKeys: [.volumeURLKey, .volumeIsInternalKey])
        return values?.volumeIsInternal == true ? values?.volume : nil
      },
      remove: { try FileManager.default.removeItem(at: $0) },
      trash: { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) })
  }

  private let allowedRoots: [URL]
  private let deniedRoots: [URL]
  private let bootVolume: URL
  private let mode: Mode
  private let hooks: Hooks
  private let lock = NSLock()
  private var touchedURLs: [URL] = []

  public init(allowedRoots: [URL], deniedRoots: [URL], bootVolume: URL, mode: Mode, hooks: Hooks = .live) {
    self.allowedRoots = allowedRoots
    self.deniedRoots = deniedRoots
    self.bootVolume = bootVolume
    self.mode = mode
    self.hooks = hooks
  }

  /// Deleted, trashed, or would-be in dry run.
  public var touched: [URL] { lock.withLock { touchedURLs } }

  /// Roots are re-read on every call, so a link that appeared after init cannot widen them.
  public func validate(_ url: URL) throws {
    if Self.isSymlink(url) { throw Refusal.symlink }

    let allowed = allowedRoots.filter { !Self.isSymlink($0) }.compactMap(Self.realPath)
    // A path that does not resolve cannot be proven safe, so it counts as outside.
    guard let path = Self.realPath(url), allowed.contains(where: { Self.isInside(path, $0) }) else {
      throw Refusal.outsideAllowedRoots
    }

    // A denied root that does not resolve holds nothing on disk, so it cannot contain `path` or be lost with it.
    let denied = deniedRoots.compactMap(Self.realPath)
    // An ancestor counts too: deleting it would take the denied root with it.
    if denied.contains(where: { path == $0 || Self.isInside(path, $0) || Self.isInside($0, path) }) {
      throw Refusal.denied
    }

    if hooks.volumeOf(URL(filePath: path)) != bootVolume { throw Refusal.notOnBootVolume }
  }

  @discardableResult public func delete(_ url: URL) throws -> Int64 { try perform(hooks.remove, on: url) }

  @discardableResult public func trash(_ url: URL) throws -> Int64 { try perform(hooks.trash, on: url) }

  private func perform(_ operation: (URL) throws -> Void, on url: URL) throws -> Int64 {
    try validate(url)
    let bytes = Self.size(of: url)
    if mode == .live { try operation(url) }
    lock.withLock { touchedURLs.append(url) }
    return bytes
  }

  // lstat, not a URL resource value: those can be cached on the URL and go stale.
  private static func isSymlink(_ url: URL) -> Bool {
    url.withUnsafeFileSystemRepresentation { path in
      var info = stat()
      guard let path, lstat(path, &info) == 0 else { return false }
      return info.st_mode & S_IFMT == S_IFLNK
    }
  }

  // realpath, not resolvingSymlinksInPath: it fails on a missing path, keeps /private,
  // and returns the on-disk case, so a case variant cannot slip past a denied root.
  private static func realPath(_ url: URL) -> String? {
    url.withUnsafeFileSystemRepresentation { path in
      guard let path, let resolved = realpath(path, nil) else { return nil }
      defer { free(resolved) }
      return String(cString: resolved)
    }
  }

  /// Strictly inside. Both paths must come from `realPath`.
  private static func isInside(_ path: String, _ root: String) -> Bool {
    path != root && path.hasPrefix(root == "/" ? root : root + "/")
  }

  private static func size(of url: URL) -> Int64 {
    func allocated(_ url: URL) -> Int64 {
      Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
    }
    var total = allocated(url)
    // The enumerator does not descend into symlinks.
    if let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) {
      for case let item as URL in items { total += allocated(item) }
    }
    return total
  }
}
