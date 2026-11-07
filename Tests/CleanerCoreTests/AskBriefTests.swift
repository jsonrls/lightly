import Foundation
import Testing
@testable import CleanerCore

struct AskBriefTests {
  let s = Sandbox()

  private func snapshot(folders: [FolderSize] = [], paused: Bool = false, fullAccess: Bool = false) -> AskBrief.Snapshot {
    let stats = StatsSnapshot(diskFreeBytes: 17_520_000_000, diskTotalBytes: 245_110_000_000, memoryUsedFraction: 0.72, cpuFraction: 0.21, batteryFraction: 1)
    return .init(stats: stats, folders: folders, lastClean: "Today, 1:06 AM", monthFreed: 5_910_000_000, paused: paused, fullAccess: fullAccess)
  }

  private let folders = [
    FolderSize(name: "Developer tools", bytes: 30_900_000_000),
    FolderSize(name: "App data", bytes: 21_600_000_000),
    FolderSize(name: "App caches", bytes: 8_800_000_000),
    FolderSize(name: "Logs", bytes: 30_000_000),
  ]

  // Measuring
  @Test func privateFoldersNeedFullAccess() {
    let names = { (full: Bool) in DiskUsage.folders(home: s.root, fullAccess: full).map(\.name) }
    #expect(!names(false).contains("Documents"))
    #expect(!names(false).contains("App containers"))
    #expect(names(true).contains("Documents"))
    #expect(names(true).contains("Trash"))
  }

  @Test func measuresBiggestFirstAndSkipsMissing() {
    s.file("big/x", bytes: 200_000)
    s.file("small/x", bytes: 1000)
    let sizes = DiskUsage.measure([("small", s.url("small")), ("big", s.url("big")), ("gone", s.url("gone"))])
    #expect(sizes.map(\.name) == ["big", "small"])
  }

  @Test func doesNotFollowLinks() {
    s.file("Elsewhere/x", bytes: 200_000)
    s.link("root", to: s.url("Elsewhere"))
    s.file("inside/x", bytes: 1000)
    s.link("inside/link", to: s.url("Elsewhere"))
    let sizes = DiskUsage.measure([("root", s.url("root")), ("inside", s.url("inside"))])
    #expect(sizes.map(\.name) == ["inside"])
    #expect(sizes[0].bytes < 100_000)
  }

  // Scanning inside locations
  @Test func scanFindsTheBiggestItemsInsideEachLocation() {
    s.file("a/big/x", bytes: 300_000)
    s.file("a/small/x", bytes: 1000)
    s.file("b/mid", bytes: 50_000)
    let scan = DiskUsage.scan([("B", s.url("b")), ("A", s.url("a")), ("gone", s.url("gone"))], limit: 2)
    #expect(scan.folders.map(\.name) == ["A", "B"])
    #expect(scan.folders[0].bytes > 300_000)
    #expect(scan.largest.map(\.name) == ["A: big", "B: mid"])
  }

  @Test func scanDoesNotFollowLinks() {
    s.file("Elsewhere/x", bytes: 300_000)
    s.link("root", to: s.url("Elsewhere"))
    s.file("inside/x", bytes: 1000)
    s.link("inside/link", to: s.url("Elsewhere"))
    let scan = DiskUsage.scan([("root", s.url("root")), ("inside", s.url("inside"))], limit: 5)
    #expect(scan.folders.map(\.name) == ["inside"])
    #expect(scan.largest.map(\.name) == ["inside: x"])
  }

  @Test func factsListTheLargestItems() {
    var snap = snapshot(folders: folders)
    snap.largest = [FolderSize(name: "Developer tools: CoreSimulator", bytes: 20_000_000_000)]
    #expect(AskBrief.facts(snap).contains("Developer tools: CoreSimulator: 20 GB"))
    #expect(AskBrief.fallback(snap).contains("Developer tools: CoreSimulator 20 GB"))
  }

  @Test func aScanAnswerMustRankTheTopThreeInOrder() {
    var snap = snapshot()
    snap.largest = [FolderSize(name: "Developer tools: Xcode", bytes: 3), FolderSize(name: "App data: Claude", bytes: 2),
                    FolderSize(name: "Developer tools: CoreSimulator", bytes: 1), FolderSize(name: "Applications: Xcode.app", bytes: 0)]
    #expect(AskBrief.ranksCorrectly("Xcode first, then Claude, then CoreSimulator.", snap))
    #expect(!AskBrief.ranksCorrectly("Xcode first, then Claude, then Xcode.app.", snap))
    #expect(!AskBrief.ranksCorrectly("Claude first, then Xcode, then CoreSimulator.", snap))
  }

  // Facts
  @Test func factsCarryTheMeasuredNumbers() {
    let facts = AskBrief.facts(snapshot(folders: folders))
    #expect(facts.contains("Disk: 17.52 GB free of 245.11 GB, 93% used"))
    #expect(facts.contains("Developer tools: 30.9 GB"))
    #expect(facts.contains("Battery: 100%"))
    #expect(facts.contains("Freed this month: 5.91 GB"))
    #expect(facts.contains("every hour"))
  }

  @Test func factsSayWhatWasNotMeasured() {
    #expect(AskBrief.facts(snapshot()).contains("Not measured"))
    #expect(!AskBrief.facts(snapshot(fullAccess: true)).contains("Not measured"))
  }

  @Test func factsReportAPause() {
    #expect(AskBrief.facts(snapshot(paused: true)).contains("Auto-clean: paused"))
  }

  // Checking answers
  @Test func acceptsAnAnswerBuiltFromTheFacts() {
    let facts = AskBrief.facts(snapshot(folders: folders))
    #expect(AskBrief.isSafe("Developer tools use the most, at 30.9 GB, then App data at 21.6 GB.", facts: facts, question: "What's using my disk?"))
  }

  @Test func rejectsAnInventedNumber() {
    let facts = AskBrief.facts(snapshot(folders: folders))
    #expect(!AskBrief.isSafe("Developer tools use 50 GB.", facts: facts, question: "What's using my disk?"))
  }

  @Test func allowsANumberFromTheQuestion() {
    let facts = AskBrief.facts(snapshot(folders: folders))
    #expect(AskBrief.isSafe("The top 2 are Developer tools and App data.", facts: facts, question: "What are the top 2?"))
  }

  @Test func rejectsDeleteAdvice() {
    let facts = AskBrief.facts(snapshot(folders: folders))
    for answer in ["You can delete Developer tools.", "Try to Remove App data.", "Erase your logs.", "Uninstall Xcode.", "Empty the Trash."] {
      #expect(!AskBrief.isSafe(answer, facts: facts, question: "How do I free space?"))
    }
  }

  @Test func fallbackListsTheBiggestThree() {
    let text = AskBrief.fallback(snapshot(folders: folders))
    #expect(text.contains("17.52 GB free"))
    #expect(text.contains("Developer tools 30.9 GB"))
    #expect(text.contains("App caches 8.8 GB"))
    #expect(!text.contains("Logs"))
  }
}
