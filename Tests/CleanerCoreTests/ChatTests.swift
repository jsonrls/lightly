import Testing
@testable import CleanerCore

struct ChatTests {
  private func turn(_ number: Int) -> ChatTurn {
    ChatTurn(question: "Question \(number)", answer: "Answer \(number)")
  }

  @Test func firstQuestionHasNoConversation() {
    let prompt = AskBrief.prompt(facts: "Disk: 19 GB free", history: [], question: "How much is free?")
    #expect(prompt == "Facts:\nDisk: 19 GB free\n\nQuestion: How much is free?")
  }

  @Test func followUpCarriesTheConversationInOrder() {
    let prompt = AskBrief.prompt(facts: "Disk: 19 GB free", history: [turn(1), turn(2)], question: "And the second?")
    #expect(prompt == """
      Facts:
      Disk: 19 GB free

      Conversation so far:
      Person: Question 1
      You: Answer 1
      Person: Question 2
      You: Answer 2

      Question: And the second?
      """)
  }

  @Test func onlyRecentTurnsAreSent() {
    let prompt = AskBrief.prompt(facts: "", history: (1...6).map(turn), question: "Next", memory: 2)
    #expect(!prompt.contains("Question 4"))
    #expect(prompt.contains("Question 5"))
    #expect(prompt.contains("Answer 6"))
  }

  @Test func unansweredTurnIsLeftOut() {
    let prompt = AskBrief.prompt(facts: "", history: [turn(1), ChatTurn(question: "Pending")], question: "Next")
    #expect(!prompt.contains("Pending"))
    #expect(prompt.contains("Question 1"))
  }

  @Test func elapsedReadsLikeAStopwatch() {
    #expect(Format.elapsed(0) == "0.0s")
    #expect(Format.elapsed(3.27) == "3.2s")
    #expect(Format.elapsed(59.99) == "59.9s")
    #expect(Format.elapsed(60) == "1m 0.0s")
    #expect(Format.elapsed(125.4) == "2m 5.4s")
  }

  @Test func loaderWaveLeadsWithTheMiddleRowAndRepeats() {
    let peak = 0.65 * 0.3
    #expect(PixelLoader.opacity(cell: 3, at: peak) == 1)
    #expect(PixelLoader.opacity(cell: 0, at: peak) < 1)  // the row above trails the middle row
    #expect(PixelLoader.opacity(cell: 2, at: 0.1) == 0.15)  // the far corner has not started
    #expect(PixelLoader.opacity(cell: 3, at: 0.65 * 0.8) == 0.15)
    #expect(PixelLoader.opacity(cell: 3, at: peak + 0.65) == 1)
  }

  @Test(arguments: [(1, "every hour"), (3, "every 3 hours"), (24, "once a day")])
  func factsNameTheScheduleInPlainWords(hours: Int, words: String) {
    let stats = StatsSnapshot(diskFreeBytes: 1, diskTotalBytes: 2, memoryUsedFraction: 0, cpuFraction: 0, batteryFraction: nil)
    let snapshot = AskBrief.Snapshot(stats: stats, folders: [], lastClean: nil, monthFreed: 0, paused: false, fullAccess: true, intervalHours: hours)
    #expect(AskBrief.facts(snapshot).contains("Auto-clean: runs by itself \(words)"))
  }

  @Test func numberedListMarkersAreNotFigures() {
    let facts = "Xcode.app: 24.52 GB\nClaude: 13.5 GB"
    #expect(AskBrief.isSafe("1. Xcode.app: 24.52 GB\n2. Claude: 13.5 GB", facts: facts, question: "List them"))
    #expect(AskBrief.isSafe("Here you go:\n   1) Xcode.app: 24.52 GB  \n   2) Claude: 13.5 GB", facts: facts, question: "List them"))
    #expect(!AskBrief.isSafe("1. Xcode.app: 31 GB\n2. Claude: 13.5 GB", facts: facts, question: "List them"))
    #expect(!AskBrief.isSafe("12.5 GB is used by Xcode", facts: facts, question: "How big?"))
    #expect(!AskBrief.isSafe("It is 31. Really.", facts: facts, question: "How big?"))
  }

  @Test func listRequestsAreRecognised() {
    #expect(AskBrief.wantsList("list down the biggest items"))
    #expect(AskBrief.wantsList("Give me a LIST of folders"))
    #expect(!AskBrief.wantsList("What's using my disk?"))
    #expect(!AskBrief.wantsList("Is this a realistic size?"))
  }

  @Test func onlyRealListsCountAsLists() {
    #expect(AskBrief.isList("1. Xcode\n2. Claude"))
    #expect(AskBrief.isList("Here:\n- Xcode\n- Claude"))
    #expect(!AskBrief.isList("Here are the biggest items: Xcode, Claude, CoreSimulator."))
    #expect(!AskBrief.isList("1. Xcode"))
  }

  @Test func listFallbackIsBuiltFromTheMeasurements() {
    let stats = StatsSnapshot(diskFreeBytes: 19_000_000_000, diskTotalBytes: 245_000_000_000, memoryUsedFraction: 0.7, cpuFraction: 0.2, batteryFraction: 1)
    let snapshot = AskBrief.Snapshot(
      stats: stats,
      folders: [FolderSize(name: "App data", bytes: 2_000_000_000)],
      largest: [FolderSize(name: "Xcode", bytes: 3_000_000_000), FolderSize(name: "Claude", bytes: 1_000_000_000)],
      lastClean: nil, monthFreed: 0, paused: false, fullAccess: false)
    #expect(AskBrief.fallback(snapshot, question: "list down the biggest items") == "1. Xcode: 3 GB\n2. Claude: 1 GB")
    #expect(AskBrief.fallback(snapshot, question: "list my folders") == "1. App data: 2 GB")
  }

  @Test func askingAboutDeletingGetsADirectReply() {
    let stats = StatsSnapshot(diskFreeBytes: 19_000_000_000, diskTotalBytes: 245_000_000_000, memoryUsedFraction: 0.7, cpuFraction: 0.2, batteryFraction: 1)
    let snapshot = AskBrief.Snapshot(stats: stats, folders: [], lastClean: nil, monthFreed: 0, paused: false, fullAccess: false)
    #expect(AskBrief.fallback(snapshot, question: "Should I delete it?").hasPrefix("I can't say"))
    #expect(AskBrief.fallback(snapshot, question: "How much is free?").hasPrefix("Your disk has"))
  }

  @Test func figureRepeatedFromAnEarlierAnswerIsAllowed() {
    let history = [ChatTurn(question: "Biggest?", answer: "Xcode at 24.52 GB.")]
    let prompt = AskBrief.prompt(facts: "Disk: 19 GB free", history: history, question: "How big was it?")
    #expect(AskBrief.isSafe("It was 24.52 GB.", facts: prompt, question: "How big was it?"))
    #expect(!AskBrief.isSafe("It was 31 GB.", facts: prompt, question: "How big was it?"))
  }
}
