import CleanerCore
import Foundation
import FoundationModels

/// A plain-words description of a finished run, written on device by Apple Intelligence.
@Generable
struct CleanInsight {
  @Guide(description: "A natural sentence in the style of: Freed 9 GB, mostly from photo thumbnails. Use the Total and Biggest figures given, not the ones in this example.")
  var headline: String

  @Guide(description: "If an Error line is given, one friendly sentence saying the folder named before the colon in the Error line could not be removed this time and will be tried again later. Do not quote the error. If there is no Error line, leave this empty.")
  var problem: String

  static var isModelAvailable: Bool {
    if case .available = SystemLanguageModel.default.availability { true } else { false }
  }

  /// nil when this Mac has no usable model, so the window shows nothing extra.
  static func explain(_ record: RunRecord) async -> CleanInsight? {
    guard isModelAvailable else { return nil }
    let session = LanguageModelSession(
      instructions: "You describe a finished disk cleanup to a non-technical person. Use only the names and figures given, exactly as written. Never suggest deleting anything.")
    do {
      var insight = try await session.respond(to: CleanBrief.facts(record), generating: CleanInsight.self).content
      if !CleanBrief.isFaithful(insight.headline, to: record) { insight.headline = CleanBrief.fallbackHeadline(record) }
      if !record.hasErrors {
        insight.problem = ""  // the model invents one when there is no error
      } else if !CleanBrief.isFaithfulProblem(insight.problem, to: record) {
        insight.problem = CleanBrief.fallbackProblem(record)
      }
      return insight
    } catch {
      NSLog("Clean insight failed: %@", "\(error)")
      return nil
    }
  }
}
