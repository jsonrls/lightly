import CleanerCore
import Foundation
import FoundationModels
import SwiftUI

@MainActor @Observable final class AskModel {
  var question = ""
  private(set) var answer: String?
  private(set) var isWorking = false
  private var measured: (date: Date, scan: (folders: [FolderSize], largest: [FolderSize]))?

  private static let scanQuestion = "What are the biggest items on this Mac, and what is each one?"

  func scan(_ model: AppModel) {
    question = Self.scanQuestion
    ask(model)
  }

  func ask(_ model: AppModel) {
    let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !question.isEmpty, !isWorking else { return }
    isWorking = true
    Task {
      let scan = await scanned(fullAccess: model.trashAccess)
      let snapshot = AskBrief.Snapshot(
        stats: model.stats,
        folders: scan.folders,
        largest: scan.largest,
        lastClean: model.lastRecord.map { "\(shortDate($0.date)), \(Format.bytes($0.totalBytes)) freed" },
        monthFreed: Format.monthlyTotal(model.state.history, now: Date(), calendar: .current),
        paused: model.state.paused,
        fullAccess: model.trashAccess,
        intervalHours: model.state.settings.intervalHours)
      answer = await Self.respond(to: question, snapshot)
      isWorking = false
    }
  }

  /// Measured off the main actor, and kept for ten minutes so follow-up questions answer quickly.
  private func scanned(fullAccess: Bool) async -> (folders: [FolderSize], largest: [FolderSize]) {
    if let measured, Date().timeIntervalSince(measured.date) < 600 { return measured.scan }
    let scan = await Task.detached {
      DiskUsage.scan(DiskUsage.folders(home: .homeDirectory, fullAccess: fullAccess))
    }.value
    measured = (Date(), scan)
    return scan
  }

  private static func respond(to question: String, _ snapshot: AskBrief.Snapshot) async -> String {
    let facts = AskBrief.facts(snapshot)
    let session = LanguageModelSession(
      instructions: """
        You answer questions about this Mac in up to three short sentences for a non-technical person.
        Use only the facts given, with figures exactly as written. If the facts do not answer the question, say so.
        When asked what items are, name the largest three and say in a few plain words what each one probably is.
        Never advise deleting, removing or uninstalling anything: Lightly cleans caches by itself.
        """)
    do {
      let answer = try await session.respond(to: "Facts:\n\(facts)\n\nQuestion: \(question)").content
      let ranked = question != scanQuestion || AskBrief.ranksCorrectly(answer, snapshot)
      return ranked && AskBrief.isSafe(answer, facts: facts, question: question) ? answer : AskBrief.fallback(snapshot)
    } catch {
      NSLog("Ask failed: %@", "\(error)")
      return AskBrief.fallback(snapshot)
    }
  }
}

/// Hidden on a Mac without Apple Intelligence, or when the owner switched it off.
struct AskPanel: View {
  let model: AppModel
  @State private var ask = AskModel()

  var body: some View {
    if CleanInsight.isModelAvailable, model.state.settings.useAppleIntelligence {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          TextField("Ask about your Mac, such as: What's using my disk?", text: $ask.question)
            .textFieldStyle(.plain)
            .onSubmit { ask.ask(model) }
          Button("Scan", systemImage: "magnifyingglass") { ask.scan(model) }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .disabled(ask.isWorking)
          if ask.isWorking {
            ProgressView().controlSize(.small)
          } else {
            Button { ask.ask(model) } label: { Image(systemName: "arrow.up") }
              .buttonStyle(.glassProminent)
              .buttonBorderShape(.circle)
              .disabled(ask.question.isEmpty)
              .accessibilityLabel("Ask")
          }
        }
        if let answer = ask.answer {
          Text(answer).font(.callout).fixedSize(horizontal: false, vertical: true)
          Label("Apple Intelligence", systemImage: "apple.intelligence").font(.caption2).foregroundStyle(.tertiary)
        }
      }
      .padding(12)
      .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }
  }
}
