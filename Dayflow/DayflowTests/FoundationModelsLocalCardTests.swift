import XCTest

@testable import Dayflow

@available(macOS 27.0, *)
final class FoundationModelsLocalCardTests: XCTestCase {
  private typealias Provider = FoundationModelsProvider

  private func timestamp(_ hour: Int, _ minute: Int, day: Int = 12) -> Int {
    Int(Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: day,
      hour: hour, minute: minute))!.timeIntervalSince1970)
  }

  private func observation(_ start: Int, _ end: Int, text: String = "Read a document") -> Observation {
    Observation(id: nil, batchId: 10, startTs: start, endTs: end, observation: text,
      metadata: nil, llmModel: "fixture", createdAt: nil)
  }

  private func card(_ start: String, _ end: String, category: String = "Work", title: String = "Earlier work") -> ActivityCardData {
    ActivityCardData(startTime: start, endTime: end, category: category, subcategory: "",
      title: title, summary: title, detailedSummary: "", distractions: nil, appSites: nil)
  }

  private func context(_ observations: [Observation], previous: [ActivityCardData] = [], cutoff: Int) -> ActivityGenerationContext {
    ActivityGenerationContext(batchObservations: observations, existingCards: previous,
      currentTime: Date(timeIntervalSince1970: TimeInterval(cutoff)), categories: [],
      hasPreviousCardWithinFiveMinutes: !previous.isEmpty)
  }

  private var content: Provider.CardContent {
    Provider.CardContent(title: "Review document", summary: "Read the document and checked references.",
      category: "Work", appSites: AppSites(primary: "Codex", secondary: nil))
  }

  private func actions(merge: Bool = false) -> Provider.CardGenerationActions {
    Provider.CardGenerationActions(summarize: { _ in self.content },
      shouldMerge: { _, _ in merge },
      merge: { _, _ in Provider.MergedContent(title: "Continue document review", summary: "Reviewed both parts.") })
  }

  func testCurrentBatchOwnsBoundsAndCannotExtendPastCaptureCutoff() async throws {
    let start = timestamp(14, 12)
    let end = timestamp(14, 27)
    let input = context([observation(start, end + 10)], cutoff: end)
    var seenEnd: Int?
    let actions = Provider.CardGenerationActions(summarize: { observations in
      seenEnd = observations.last?.endTs
      return self.content
    }, shouldMerge: { _, _ in XCTFail("No previous card"); return false },
      merge: { _, _ in throw CancellationError() })
    let cards = try await Provider.composeActivityCards(context: input, actions: actions)
    XCTAssertEqual(seenEnd, end)
    XCTAssertEqual(cards.count, 1)
    XCTAssertEqual(cards[0].startTime, "2:12 PM")
    XCTAssertEqual(cards[0].endTime, "2:27 PM")
    XCTAssertEqual(cards[0].appSites?.primary, "Codex")
  }

  func testIdleWithoutObservationsIsPreservedWithoutRegenerationOrMerge() async throws {
    let start = timestamp(2, 48)
    let end = timestamp(3, 3)
    let input = context([observation(start, end)],
      previous: [card("2:18 AM", "2:48 AM", category: "Idle", title: "Idle")], cutoff: end)
    let actions = Provider.CardGenerationActions(summarize: { observations in
      XCTAssertEqual(observations.map(\.startTs), [start])
      return self.content
    }, shouldMerge: { _, _ in XCTFail("Idle must remain separate"); return true },
      merge: { _, _ in throw CancellationError() })
    let cards = try await Provider.composeActivityCards(context: input, actions: actions)
    XCTAssertEqual(cards.map(\.category), ["Idle", "Work"])
    XCTAssertEqual(cards.map(\.startTime), ["2:18 AM", "2:48 AM"])
    XCTAssertEqual(cards.map(\.endTime), ["2:48 AM", "3:03 AM"])
  }

  func testStoredCardSuffixIsPreservedWithoutDuplicatingCardsOutsideReplacementWindow() async throws {
    let start = timestamp(14, 27)
    let end = timestamp(14, 42)
    let input = context([observation(start, end)], previous: [
      card("1:42 PM", "2:27 PM"), card("2:27 PM", "3:00 PM"),
      card("3:00 PM", "3:27 PM", category: "Idle")], cutoff: end)
    let cards = try await Provider.composeActivityCards(context: input, actions: actions())
    XCTAssertEqual(cards.map(\.startTime), ["1:42 PM", "2:27 PM", "2:42 PM"])
    XCTAssertEqual(cards.map(\.endTime), ["2:27 PM", "2:42 PM", "3:00 PM"])
  }

  func testReprocessingPreservesBothSidesOfAnOverlappingStoredCard() async throws {
    let input = context([observation(timestamp(15, 0), timestamp(15, 15))],
      previous: [card("2:42 PM", "4:05 PM")], cutoff: timestamp(15, 15))
    let cards = try await Provider.composeActivityCards(context: input, actions: actions())
    XCTAssertEqual(cards.map(\.startTime), ["2:42 PM", "3:00 PM", "3:15 PM"])
    XCTAssertEqual(cards.map(\.endTime), ["3:00 PM", "3:15 PM", "4:05 PM"])
    XCTAssertEqual(cards.map(\.title), ["Earlier work", "Review document", "Earlier work"])
  }

  func testReprocessingFirstBatchOfMergedCardKeepsLaterActivity() async throws {
    let input = context([observation(timestamp(14, 0), timestamp(14, 15))],
      previous: [card("2:00 PM", "2:45 PM")], cutoff: timestamp(14, 15))

    let cards = try await Provider.composeActivityCards(context: input, actions: actions())

    XCTAssertEqual(cards.map(\.startTime), ["2:00 PM", "2:15 PM"])
    XCTAssertEqual(cards.map(\.endTime), ["2:15 PM", "2:45 PM"])
    XCTAssertEqual(cards.map(\.title), ["Review document", "Earlier work"])
  }

  func testOptionalMergeOnlyChangesTheReprocessedPrefixAndKeepsTheSuffix() async throws {
    let input = context([observation(timestamp(14, 0), timestamp(14, 15))],
      previous: [card("1:45 PM", "2:45 PM")], cutoff: timestamp(14, 15))

    let cards = try await Provider.composeActivityCards(context: input, actions: actions(merge: true))

    XCTAssertEqual(cards.map(\.startTime), ["1:45 PM", "2:15 PM"])
    XCTAssertEqual(cards.map(\.endTime), ["2:15 PM", "2:45 PM"])
    XCTAssertEqual(cards.map(\.title), ["Continue document review", "Earlier work"])
  }

  func testMergeAcrossMidnightUsesExistingBoundaries() async throws {
    let input = context([observation(timestamp(0, 0, day: 13), timestamp(0, 15, day: 13))],
      previous: [card("11:45 PM", "12:00 AM")], cutoff: timestamp(0, 15, day: 13))
    let cards = try await Provider.composeActivityCards(context: input, actions: actions(merge: true))
    XCTAssertEqual(cards.count, 1)
    XCTAssertEqual(cards[0].startTime, "11:45 PM")
    XCTAssertEqual(cards[0].endTime, "12:15 AM")
    XCTAssertEqual(cards[0].title, "Continue document review")
  }

  func testLongPreviousCardAndDisconnectedCardSkipMergeDecision() async throws {
    for previous in [card("1:20 PM", "2:00 PM"), card("1:30 PM", "1:54 PM")] {
      let input = context([observation(timestamp(14, 0), timestamp(14, 15))],
        previous: [previous], cutoff: timestamp(14, 15))
      let actions = Provider.CardGenerationActions(summarize: { _ in self.content },
        shouldMerge: { _, _ in XCTFail("Duration/gap guard should skip the model"); return true },
        merge: { _, _ in throw CancellationError() })
      let cards = try await Provider.composeActivityCards(context: input, actions: actions)
      XCTAssertEqual(cards.count, 2)
    }
  }

  func testOptionalMergeFailureKeepsBothUsableCards() async throws {
    let input = context([observation(timestamp(14, 15), timestamp(14, 30))],
      previous: [card("2:00 PM", "2:15 PM")], cutoff: timestamp(14, 30))
    let actions = Provider.CardGenerationActions(summarize: { _ in self.content },
      shouldMerge: { _, _ in true }, merge: { _, _ in throw NSError(domain: "Model boundary", code: 1) })
    let cards = try await Provider.composeActivityCards(context: input, actions: actions)
    XCTAssertEqual(cards.map(\.endTime), ["2:15 PM", "2:30 PM"])
    XCTAssertEqual(cards.last?.title, "Review document")
  }

  func testCancellationDuringMergePropagates() async {
    let input = context([observation(timestamp(14, 15), timestamp(14, 30))],
      previous: [card("2:00 PM", "2:15 PM")], cutoff: timestamp(14, 30))
    let actions = Provider.CardGenerationActions(summarize: { _ in self.content },
      shouldMerge: { _, _ in throw CancellationError() },
      merge: { _, _ in throw CancellationError() })
    do {
      _ = try await Provider.composeActivityCards(context: input, actions: actions)
      XCTFail("Cancellation must not turn into a successful fallback")
    } catch is CancellationError {
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testMaterialObservationGapCannotBecomeOneContinuousCard() async {
    let input = context([
      observation(timestamp(14, 0), timestamp(14, 5)),
      observation(timestamp(14, 12), timestamp(14, 20))], cutoff: timestamp(14, 20))
    do {
      _ = try await Provider.composeActivityCards(context: input, actions: actions())
      XCTFail("Missing evidence must not become continuous activity")
    } catch let error as ClaudeOutputValidationError {
      guard case .cardCoversEvidenceGap = error else { return XCTFail("Unexpected error: \(error)") }
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testLiveContentGenerationPreservesIdleAndCurrentBounds() async throws {
    guard ProcessInfo.processInfo.environment["DAYFLOW_FM_LIVE_CARDS"] == "1" else {
      throw XCTSkip("Set DAYFLOW_FM_LIVE_CARDS=1 for local model integration")
    }
    guard Provider.availability() == .available else { throw XCTSkip("On-device model unavailable") }
    let start = timestamp(14, 0)
    let end = timestamp(14, 15)
    let observations = (0..<3).map { index in
      observation(start + index * 300, start + (index + 1) * 300,
        text: "Safari: Reading Swift documentation about async functions. Evidence: Swift concurrency code examples.")
    }
    let categories = [LLMCategoryDescriptor(id: UUID(), name: "Work", colorHex: "#000000",
      description: "Programming and technical reading", isSystem: false, isIdle: false),
      LLMCategoryDescriptor(id: UUID(), name: "Idle", colorHex: "#999999",
        description: "Away from the computer", isSystem: true, isIdle: true)]
    let input = ActivityGenerationContext(batchObservations: observations,
      existingCards: [card("1:30 PM", "2:00 PM", category: "Idle", title: "Idle")],
      currentTime: Date(timeIntervalSince1970: TimeInterval(end)), categories: categories,
      hasPreviousCardWithinFiveMinutes: true)
    let result = try await Provider(logsCalls: false).generateActivityCards(
      observations: observations, context: input, batchId: nil)
    XCTAssertEqual(result.cards.count, 2)
    XCTAssertEqual(result.cards[0].category, "Idle")
    XCTAssertEqual(result.cards[1].startTime, "2:00 PM")
    XCTAssertEqual(result.cards[1].endTime, "2:15 PM")
    XCTAssertFalse(result.cards[1].title.isEmpty)
    XCTAssertFalse(result.cards[1].summary.isEmpty)
    print("FM local-card integration completed in \(result.log.latency) seconds")
  }
}
