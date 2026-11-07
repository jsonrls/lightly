import Foundation
import Testing
@testable import CleanerCore

@Test func cpuDelta() {
  #expect(SystemStats.cpuFraction(previous: .init(busy: 100, total: 1000), current: .init(busy: 150, total: 1200)) == 0.25)
}
@Test func cpuZeroDelta() {
  #expect(SystemStats.cpuFraction(previous: .init(busy: 1, total: 1), current: .init(busy: 1, total: 1)) == 0)
}
@Test func sampleIsSane() {
  let stats = SystemStats(volume: URL(filePath: "/"))
  let first = stats.sample()
  #expect(first.cpuFraction == 0)
  let s = stats.sample()
  #expect(s.diskFreeBytes > 0 && s.diskFreeBytes <= s.diskTotalBytes)
  #expect((0...1).contains(s.memoryUsedFraction))
  #expect((0...1).contains(s.cpuFraction))
  if let b = s.batteryFraction { #expect((0...1).contains(b)) }
}
@Test func menuBarText() {
  #expect(Format.menuBarText(freeBytes: 212_000_000_000, memoryFraction: 0.61) == "212 GB · 61%")
}
@Test func byteText() {
  #expect(Format.bytes(640_000_000) == "640 MB")
  #expect(Format.bytes(1_200_000_000) == "1.2 GB")
  #expect(Format.bytes(0) == "0 bytes")
}
@Test func monthlyTotalCountsThisMonthOnly() {
  var cal = Calendar(identifier: .gregorian)
  cal.timeZone = TimeZone(identifier: "UTC")!
  func rec(_ m: Int, _ d: Int, _ bytes: Int64) -> RunRecord {
    let date = cal.date(from: DateComponents(year: 2026, month: m, day: d, hour: 12))!
    return RunRecord(date: date, manual: false, results: [CleanResult(category: .logs, bytesFreed: bytes, errors: [])])
  }
  let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 9))!
  #expect(Format.monthlyTotal([rec(11, 2, 10), rec(11, 5, 5), rec(10, 30, 99)], now: now, calendar: cal) == 15)
}
@Test func everyIntervalChoiceHasAName() {
  #expect(CleanSettings.intervalChoices.map(Format.interval) == ["Every hour", "Every 3 hours", "Every 6 hours", "Every 12 hours", "Once a day"])
}
@Test func monthInsightSummarisesThisMonthOnly() {
  var cal = Calendar(identifier: .gregorian)
  cal.timeZone = TimeZone(identifier: "UTC")!
  let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 9))!
  let lastMonth = cal.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 9))!
  func rec(_ date: Date, _ freed: [(CleanCategory, Int64)]) -> RunRecord {
    RunRecord(date: date, manual: false, results: freed.map { CleanResult(category: $0.0, bytesFreed: $0.1, errors: []) })
  }
  let insight = { (history: [RunRecord]) in Format.monthInsight(history, now: now, calendar: cal) }

  #expect(insight([]) == nil)
  #expect(insight([rec(lastMonth, [(.logs, 9_000_000)])]) == nil)
  #expect(insight([rec(now, [(.logs, 0)])]) == "This month: 1 clean, nothing needed removing.")
  #expect(insight([rec(now, [(.appCaches, 3_000_000), (.logs, 1_000_000)]), rec(now, []), rec(lastMonth, [(.logs, 9_000_000)])])
    == "This month: 4 MB freed in 2 cleans, mostly \(CleanCategory.appCaches.displayName).")
  // No category holds more than half, so none is called "mostly".
  #expect(insight([rec(now, [(.appCaches, 2_000_000), (.logs, 2_000_000)])]) == "This month: 4 MB freed in 1 clean.")
}
