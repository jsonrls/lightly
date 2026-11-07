import AppKit

public struct CleanEnvironment: Sendable {
  public var home: URL
  public var bootVolume: URL
  public var appDirs: [URL]
  public var runningBundleIDs: @Sendable () -> Set<String>
  public var appExistsAnywhere: @Sendable (String) -> Bool  // LaunchServices lookup or currently running
  public var runner: any CommandRunner
  public var hooks: DeletionGateway.Hooks
  public var trashDateAdded: @Sendable (URL) -> Date?
  public var mode: DeletionGateway.Mode

  public static func live(mode: DeletionGateway.Mode) -> CleanEnvironment {
    let home = URL.homeDirectory
    let hooks = DeletionGateway.Hooks.live
    let running: @Sendable () -> Set<String> = {
      Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }
    return CleanEnvironment(
      home: home,
      // Unknown volume: a path under a device file can never be a mount point, so the gateway refuses everything.
      bootVolume: hooks.volumeOf(home) ?? URL(filePath: "/dev/null/no-volume"),
      appDirs: [URL(filePath: "/Applications", directoryHint: .isDirectory),
                home.appending(path: "Applications", directoryHint: .isDirectory)],
      runningBundleIDs: running,
      appExistsAnywhere: { id in
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil || running().contains(id)
      },
      runner: ProcessRunner(),
      hooks: hooks,
      trashDateAdded: TrashRule.systemDateAdded,
      mode: mode)
  }

  public var allowedRoots: [URL] {
    let devDirs = DevCacheRule.wholeCacheDirs(home: home, environment: ProcessInfo.processInfo.environment)
      + [DevCacheRule.derivedDataDir(home: home)]
    return [
      "Library/Caches", "Library/Logs", ".Trash", "Library/Application Support", "Library/Preferences",
      "Library/Saved Application State", "Library/HTTPStorages", "Library/WebKit",
    ].map { home.appending(path: $0, directoryHint: .isDirectory) }
      // .npmrc and npm_config_cache can point anywhere, and every root must stay under home.
      + devDirs.filter { $0.pathComponents.starts(with: home.pathComponents) && !$0.pathComponents.contains("..") }
  }

  public var deniedRoots: [URL] {
    let browsers = ["Google/Chrome", "Firefox", "BraveSoftware", "Microsoft Edge", "Arc",
                    "com.operasoftware.Opera", "com.operasoftware.OperaGX"]
    return ([
      "Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music", "Library/Mail", "Library/Messages",
      "Library/Mobile Documents", "Library/Keychains", "Library/Safari", "Library/Containers",
      "Library/Group Containers",
    ] + browsers.map { "Library/Application Support/\($0)" })
      .map { home.appending(path: $0, directoryHint: .isDirectory) }
  }
}

public enum CleanSession {
  public static func run(env: CleanEnvironment, state: inout AppState, now: Date, manual: Bool) -> (record: RunRecord, touched: [URL]) {
    var next = state
    next.inventory.update(present: InstalledApps.scan(env.appDirs), now: now)

    let library = env.home.appending(path: "Library", directoryHint: .isDirectory)
    var leftovers: [String] = []
    for id in next.inventory.due(now: now) {
      if env.appExistsAnywhere(id) || LeftoverRule.recentlyUsed(libraryDir: library, bundleID: id, now: now)
        || LeftoverRule.holdsBrowserData(libraryDir: library, bundleID: id) {
        next.inventory.resetClock(id, now: now)
      } else {
        leftovers.append(id)
      }
    }

    let settings = next.settings
    let gateway = DeletionGateway(allowedRoots: env.allowedRoots, deniedRoots: env.deniedRoots,
                                  keptRoots: settings.keptFolders.map { URL(filePath: $0) },
                                  bootVolume: env.bootVolume, mode: env.mode, hooks: env.hooks)
    let rules: [any CleanRule] = [
      // First: the cache and log rules would delete for good what belongs in the Trash.
      LeftoverRule(libraryDir: library, bundleIDs: leftovers),
      CacheRule(cachesDir: library.appending(path: "Caches", directoryHint: .isDirectory),
                runningBundleIDs: env.runningBundleIDs, installedBundleIDs: next.inventory.installed),
      LogRule(logsDir: library.appending(path: "Logs", directoryHint: .isDirectory)),
      TrashRule(trashDir: env.home.appending(path: ".Trash", directoryHint: .isDirectory), dateAdded: env.trashDateAdded),
      DevCacheRule(home: env.home),
      DockerRule(home: env.home, runner: env.runner, mode: env.mode, isOnBootVolume: { url in
        DeletionGateway.realPath(url).map { env.hooks.volumeOf(URL(filePath: $0)) == env.bootVolume } ?? false
      }),
    ]
    let runWeekly = manual || Scheduler.weeklyDue(now: now, lastWeeklyRun: next.lastWeeklyRun)
    let results = rules.filter { (runWeekly || !$0.weekly) && !settings.disabled.contains($0.category) }
      .map { $0.run(gateway: gateway, now: now) }

    next.inventory.markCleaned(leftovers.filter { id in
      !LeftoverRule.candidates(libraryDir: library, bundleID: id).contains(where: LeftoverRule.exists)
    })
    let record = RunRecord(date: now, manual: manual, results: results)
    next.history.append(record)
    if !manual { next.lastScheduledRun = now }
    if runWeekly { next.lastWeeklyRun = now }
    next.prune(now: now)

    if env.mode == .live { state = next }
    return (record, gateway.touched)
  }
}
