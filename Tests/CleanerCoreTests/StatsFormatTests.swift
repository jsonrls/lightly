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
