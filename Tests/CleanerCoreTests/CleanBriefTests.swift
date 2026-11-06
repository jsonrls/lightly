import Foundation
import Testing
@testable import CleanerCore

struct CleanBriefTests {
  private func record(errors: [String] = []) -> RunRecord {
    RunRecord(date: .now, manual: true, results: [
      CleanResult(category: .logs, bytesFreed: 143_500_000, errors: []),
      CleanResult(category: .docker, bytesFreed: 0, errors: []),
      CleanResult(category: .appCaches, bytesFreed: 906_500_000, errors: errors),
      CleanResult(category: .devCaches, bytesFreed: 4_780_000_000, errors: []),
    ])
  }

  @Test func factsNameTheBiggestCategory() {
    let facts = CleanBrief.facts(record())
    #expect(facts.contains("Total freed: 5.83 GB"))
    #expect(facts.contains("Biggest: Developer caches, 4.78 GB"))
    #expect(facts.contains("Logs: 143.5 MB"))
  }

  @Test func factsSkipEmptyCategories() {
    #expect(!CleanBrief.facts(record()).contains("Docker"))
  }

  @Test func factsCapErrors() {
    let long = String(repeating: "x", count: 500)
    let facts = CleanBrief.facts(record(errors: Array(repeating: long, count: 10)))
    #expect(facts.components(separatedBy: "Error: ").count - 1 == 3)
    #expect(facts.contains("More errors: 7"))
    #expect(!facts.contains(String(repeating: "x", count: 201)))
  }

  @Test func acceptsATrueHeadline() {
    #expect(CleanBrief.isFaithful("Freed 5.83 GB, mostly from Developer caches, 4.78 GB.", to: record()))
    #expect(CleanBrief.isFaithful("Freed 5.83 GB, mostly from developer caches.", to: record()))
  }

  @Test func rejectsTheWrongBiggestCategory() {
    #expect(!CleanBrief.isFaithful("Freed 5.83 GB, mostly from App caches.", to: record()))
  }

  @Test func rejectsAnInventedNumber() {
    #expect(!CleanBrief.isFaithful("Freed 5.83 GB, mostly from Developer caches, 9 GB.", to: record()))
  }

  @Test func rejectsAMissingTotal() {
    #expect(!CleanBrief.isFaithful("Mostly from Developer caches.", to: record()))
  }

  @Test func rejectsAnyStoryAboutAnEmptyRun() {
    let empty = RunRecord(date: .now, manual: true, results: [CleanResult(category: .logs, bytesFreed: 0, errors: [])])
    #expect(!CleanBrief.isFaithful("Freed 0 bytes, mostly from temporary files.", to: empty))
  }

  @Test func problemMustNameTheFailedFolder() {
    let failed = record(errors: ["dotslash: couldn’t be removed"])
    #expect(CleanBrief.isFaithfulProblem("The dotslash folder could not be removed and will be tried again.", to: failed))
    #expect(!CleanBrief.isFaithfulProblem("The Photos folder could not be removed and will be tried again.", to: failed))
    #expect(!CleanBrief.isFaithfulProblem("dotslash and 9 more folders could not be removed.", to: failed))
  }

  @Test func fallbackProblemNamesTheFolderWhenItCan() {
    #expect(CleanBrief.fallbackProblem(record(errors: ["dotslash: couldn’t be removed"]))
      == "dotslash could not be removed this time and will be tried again later.")
    #expect(CleanBrief.fallbackProblem(record(errors: ["prune timed out"]))
      == "One item could not be removed this time and will be tried again later.")
    #expect(!CleanBrief.isFaithfulProblem("anything", to: record(errors: ["prune timed out"])))
  }

  @Test func fallbackStatesTheFacts() {
    #expect(CleanBrief.fallbackHeadline(record()) == "Freed 5.83 GB, mostly from Developer caches.")
    let empty = RunRecord(date: .now, manual: true, results: [CleanResult(category: .logs, bytesFreed: 0, errors: [])])
    #expect(CleanBrief.fallbackHeadline(empty) == "Nothing needed cleaning.")
  }
}
