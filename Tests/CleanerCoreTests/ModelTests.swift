import Foundation
import Testing
@testable import CleanerCore

@Test func categoryNames() {
  #expect(CleanCategory.allCases.map(\.displayName) ==
    ["App caches", "Logs", "Trash (30+ days)", "App leftovers", "Developer caches", "Docker build cache"])
}
@Test func recordTotals() {
  let r = RunRecord(date: .now, manual: false, results: [
    CleanResult(category: .logs, bytesFreed: 10, errors: []),
    CleanResult(category: .trash, bytesFreed: 5, errors: ["x"])])
  #expect(r.totalBytes == 15); #expect(r.hasErrors)
}
