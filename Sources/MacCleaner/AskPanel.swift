import CleanerCore
import Foundation
import FoundationModels
import SwiftUI

@MainActor @Observable final class AskModel {
  var question = ""
  private(set) var turns: [ChatTurn] = []
  private(set) var isWorking = false
  private var measured: (date: Date, scan: (folders: [FolderSize], largest: [FolderSize]))?

  private static let scanQuestion = "What are the biggest items on this Mac, and what is each one?"

  func scan(_ model: AppModel) {
    send(Self.scanQuestion, model)
  }

  func ask(_ model: AppModel) {
    send(question, model)
  }

  private func send(_ text: String, _ model: AppModel) {
    let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !question.isEmpty, !isWorking else { return }
    let history = turns
    turns.append(ChatTurn(question: question))
    self.question = ""
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
      turns[turns.count - 1].answer = await Self.respond(to: question, history: history, snapshot)
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

  private static func respond(to question: String, history: [ChatTurn], _ snapshot: AskBrief.Snapshot) async -> String {
    let prompt = AskBrief.prompt(facts: AskBrief.facts(snapshot), history: history, question: question)
    let session = LanguageModelSession(
      instructions: """
        You are Dusty, the assistant in the Lightly app, running on this Mac with Apple Intelligence.
        You chat with a non-technical person about their Mac. Answer only what was asked, in short plain words, and start with the answer.
        If the person only greets or thanks you, reply in one short sentence with no figures.
        If asked to list something, reply with a numbered list, one item per line, each with its size, using every matching item in the facts or the number asked for.
        Otherwise reply in up to three short sentences.
        Use the conversation so far to understand follow-up questions.
        Use only the facts given, with figures exactly as written. If the facts do not answer the question, say so.
        When asked what items are, name the largest three and say in a few plain words what each one probably is.
        Never advise deleting, removing or uninstalling anything: Lightly cleans caches by itself.
        """)
    do {
      let answer = try await session.respond(to: prompt).content
      let ranked = question != scanQuestion || AskBrief.ranksCorrectly(answer, snapshot)
      let listed = !AskBrief.wantsList(question) || AskBrief.isList(answer)
      return ranked && listed && AskBrief.isSafe(answer, facts: prompt, question: question) ? answer : AskBrief.fallback(snapshot, question: question)
    } catch {
      NSLog("Ask failed: %@", "\(error)")
      return AskBrief.fallback(snapshot, question: question)
    }
  }
}

/// Hidden on a Mac without Apple Intelligence, or when the owner switched it off.
struct AskPanel: View {
  let model: AppModel
  @Bindable var ask: AskModel
  @State private var chatHeight: CGFloat = 0

  var body: some View {
    if CleanInsight.isModelAvailable, model.state.settings.useAppleIntelligence {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Label("Dusty", systemImage: "apple.intelligence").font(.caption2).foregroundStyle(.tertiary)
          Spacer()
          Button("Scan", systemImage: "magnifyingglass") { ask.scan(model) }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .disabled(ask.isWorking)
        }
        if !ask.turns.isEmpty { conversation }
        HStack(spacing: 8) {
          TextField("Ask Dusty about your Mac, such as: What's using my disk?", text: $ask.question)
            .textFieldStyle(.plain)
            .onSubmit { ask.ask(model) }
          let canSend = !ask.question.isEmpty && !ask.isWorking
          Button { ask.ask(model) } label: {
            Image(systemName: "arrow.up").frame(width: 30, height: 30).contentShape(.circle)
          }
          .buttonStyle(.plain)
          .foregroundStyle(canSend ? Color.white : Color.secondary)
          .glassEffect(canSend ? .regular.tint(.accentColor).interactive() : .regular, in: .circle)
          .disabled(!canSend)
          .accessibilityLabel("Ask Dusty")
        }
      }
      .padding(12)
      .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }
  }

  private var conversation: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        ForEach(ask.turns) { turn in
          Text(turn.question)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.tint.opacity(0.25), in: .rect(cornerRadius: 14))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 60)
          if let answer = turn.answer {
            Text(answer).textSelection(.enabled).padding(.trailing, 60)
          } else {
            ThinkingIndicator()
          }
        }
      }
      .font(.callout)
      .fixedSize(horizontal: false, vertical: true)
      .onGeometryChange(for: CGFloat.self, of: \.size.height) { chatHeight = $0 }
    }
    .defaultScrollAnchor(.bottom)
    .defaultScrollAnchor(.bottom, for: .sizeChanges)
    .frame(height: min(chatHeight, 170))  // as tall as the chat, up to what still fits a laptop screen
  }
}

/// Pixel grid, shimmering label and a live timer. Reduced motion stills the grid and label, the timer keeps ticking.
private struct ThinkingIndicator: View {
  @State private var start = Date()
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    TimelineView(.animation(minimumInterval: reduceMotion ? 0.1 : nil)) { context in
      let seconds = context.date.timeIntervalSince(start)
      HStack(spacing: 10) {
        grid(seconds)
        label(seconds)
        Text(Format.elapsed(seconds))
          .font(.system(size: 12, design: .monospaced))
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Dusty is thinking")
  }

  private func grid(_ seconds: Double) -> some View {
    Grid(horizontalSpacing: 1.5, verticalSpacing: 1.5) {
      ForEach(0..<3, id: \.self) { row in
        GridRow {
          ForEach(0..<3, id: \.self) { column in
            RoundedRectangle(cornerRadius: 1)
              .fill(.primary)
              .frame(width: 4, height: 4)
              .opacity(reduceMotion ? 0.15 : PixelLoader.opacity(cell: row * 3 + column, at: seconds))
          }
        }
      }
    }
  }

  /// A bright band sweeps from just left of the word to just right of it, every 1.4 seconds.
  private func label(_ seconds: Double) -> some View {
    let center = -0.5 + 2 * (seconds / 1.4).truncatingRemainder(dividingBy: 1)
    let shimmer = LinearGradient(
      colors: [.secondary, .primary, .secondary],
      startPoint: UnitPoint(x: center - 0.3, y: 0.5),
      endPoint: UnitPoint(x: center + 0.3, y: 0.5))
    return Text("Thinking")
      .fontWeight(.medium)
      .foregroundStyle(reduceMotion ? AnyShapeStyle(.secondary) : AnyShapeStyle(shimmer))
  }
}
