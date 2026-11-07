import Foundation

/// The only path to file deletion in the app. Everything it refuses stays on disk.
public final class DeletionGateway: @unchecked Sendable {
  public enum Mode: Sendable { case live, dryRun }
  public enum Refusal: Error, Equatable { case symlink, outsideAllowedRoots, denied, kept, notOnBootVolume }

  public struct Hooks: Sendable {
    public var volumeOf: @Sendable (URL) -> URL?  // nil = unknown or not internal
    public var remove: @Sendable (URL) throws -> Void
    public var trash: @Sendable (URL) throws -> Void

    public static let live = Hooks(
      volumeOf: { url in
        let values = try? url.resourceValues(forKeys: [.volumeURLKey, .volumeIsInternalKey])
        return values?.volumeIsInternal == true ? values?.volume : nil
      },
      remove: { try DeletionGateway.removeTree($0) },
      trash: { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) })
  }

  private let allowedRoots: [URL]
  private let deniedRoots: [URL]
  private let keptRoots: [URL]
  private let bootVolume: URL
  private let mode: Mode
  private let hooks: Hooks
  private let lock = NSLock()
  private var touchedURLs: [URL] = []

  public init(allowedRoots: [URL], deniedRoots: [URL], keptRoots: [URL] = [], bootVolume: URL, mode: Mode, hooks: Hooks = .live) {
    self.allowedRoots = allowedRoots
    self.deniedRoots = deniedRoots
    self.keptRoots = keptRoots
    self.bootVolume = bootVolume
    self.mode = mode
    self.hooks = hooks
  }

  /// Deleted, trashed, or would-be in dry run.
  public var touched: [URL] { lock.withLock { touchedURLs } }

  /// Deletes through folder descriptors, never by path, so a folder swapped for a link after
  /// `validate` fails the open instead of redirecting the delete. A link inside the tree is removed, not followed.
  /// `device` is for tests; by default the target's own volume is the only one touched.
  static func removeTree(_ url: URL, device: dev_t? = nil) throws {
    // O_NOFOLLOW_ANY: a link anywhere in the parent's path fails the open.
    let parent = url.deletingLastPathComponent().withUnsafeFileSystemRepresentation { path in
      path.map { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY) } ?? -1
    }
    guard parent >= 0 else { throw posixError() }
    defer { close(parent) }
    var info = stat()
    let name = url.lastPathComponent
    guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw posixError() }
    try removeEntry(name, in: parent, device: device ?? info.st_dev)
  }

  /// Tools such as dotslash keep caches in read-only folders, so readable folders get the owner
  /// write bit. An unreadable folder still means keep, and another volume is never touched.
  private static func removeEntry(_ name: String, in dir: Int32, device: dev_t) throws {
    var info = stat()
    guard fstatat(dir, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw posixError() }
    guard info.st_mode & S_IFMT == S_IFDIR else {
      guard unlinkat(dir, name, 0) == 0 else { throw posixError() }
      return
    }
    guard info.st_dev == device else { throw POSIXError(.EXDEV) }
    let fd = openat(dir, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard fd >= 0 else { throw posixError() }
    defer { close(fd) }
    if info.st_mode & S_IWUSR == 0 {
      guard info.st_mode & 0o500 == 0o500 else { throw POSIXError(.EACCES) }
      fchmod(fd, info.st_mode & 0o7777 | S_IWUSR)
    }
    for child in try names(in: fd) { try removeEntry(child, in: fd, device: device) }
    guard unlinkat(dir, name, AT_REMOVEDIR) == 0 else { throw posixError() }
  }

  private static func names(in fd: Int32) throws -> [String] {
    guard let dir = fdopendir(dup(fd)) else { throw posixError() }
    defer { closedir(dir) }
    var names: [String] = []
    while let entry = readdir(dir) {
      let name = withUnsafeBytes(of: entry.pointee.d_name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
      if name != "." && name != ".." { names.append(name) }
    }
    return names
  }

  private static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

  /// Roots are re-read on every call, so a link that appeared after init cannot widen them.
  public func validate(_ url: URL) throws {
    if Self.isSymlink(url) { throw Refusal.symlink }

    // A path that does not resolve cannot be proven safe, so it counts as outside.
    guard let path = Self.realPath(url) else { throw Refusal.outsideAllowedRoots }

    // Before the roots: a location redirected to another volume is a silent skip, not an error.
    if hooks.volumeOf(URL(filePath: path)) != bootVolume { throw Refusal.notOnBootVolume }

    let allowed = allowedRoots.filter { !Self.isSymlink($0) }.compactMap(Self.realPath)
    guard allowed.contains(where: { Self.isInside(path, $0) }) else { throw Refusal.outsideAllowedRoots }

    // A denied root that does not resolve holds nothing on disk, so it cannot contain `path` or be lost with it.
    let denied = deniedRoots.compactMap(Self.realPath)
    // An ancestor counts too: deleting it would take the denied root with it.
    if denied.contains(where: { path == $0 || Self.isInside(path, $0) || Self.isInside($0, path) }) {
      throw Refusal.denied
    }

    // The owner's own list, so a refusal here is a choice, not a problem. If a kept path cannot be resolved, compare it as written.
    let kept = keptRoots.map { Self.realPath($0) ?? $0.path(percentEncoded: false) }
    if kept.contains(where: { path == $0 || Self.isInside(path, $0) || Self.isInside($0, path) }) {
      throw Refusal.kept
    }
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
  static func realPath(_ url: URL) -> String? {
    url.withUnsafeFileSystemRepresentation { path in
      guard let path, let resolved = realpath(path, nil) else { return nil }
      defer { free(resolved) }
      return String(cString: resolved)
    }
  }

  /// Strictly inside. Both paths must come from `realPath`.
  // Bytes, not hasPrefix: that compares graphemes, and a combining mark after the slash merges with it.
  private static func isInside(_ path: String, _ root: String) -> Bool {
    path != root && path.utf8.starts(with: (root == "/" ? root : root + "/").utf8)
  }

  static func size(of url: URL) -> Int64 {
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
