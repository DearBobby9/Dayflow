import AppKit
import FoundationModels
import XCTest

@testable import Dayflow

@available(macOS 27.0, *)
final class FoundationModelsProviderTests: XCTestCase {
  private func makeScreenshots(count: Int) throws -> [Screenshot] {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "FoundationModelsRetryTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let image = try XCTUnwrap(NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8,
      samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0))
    let jpeg = try XCTUnwrap(image.representation(using: .jpeg, properties: [:]))
    return try (0..<count).map { index in
      let url = directory.appendingPathComponent("frame-\(index).jpg")
      try jpeg.write(to: url)
      return Screenshot(id: Int64(index), capturedAt: 1000 + index * 60,
        filePath: url.path, fileSize: nil, idleSecondsAtCapture: nil, isDeleted: false)
    }
  }

  func testTranscriptionRetriesOnceAndReturnsRecoveredResult() async throws {
    let screenshots = try makeScreenshots(count: 1)
    var calls = 0
    let provider = FoundationModelsProvider(logsCalls: false, modelAvailability: { .available }) {
      _, _, _, _ in
      calls += 1
      if calls == 1 {
        throw LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: "Temporary failure"))
      }
      return .init(app: "Xcode", activity: "Read code", evidence: "Swift file")
    }
    let result = try await provider.transcribeScreenshots(
      screenshots, batchStartTime: screenshots[0].capturedDate, batchId: 7)
    XCTAssertEqual(calls, 2)
    XCTAssertEqual(result.observations.count, 1)
    XCTAssertTrue(result.observations[0].observation.contains("Read code"))
  }

  func testTranscriptionExhaustsExactlyTwoAttemptsBeforeReturningFailure() async throws {
    let screenshots = try makeScreenshots(count: 1)
    var calls = 0
    let provider = FoundationModelsProvider(logsCalls: false, modelAvailability: { .available }) {
      _, _, _, _ in
      calls += 1
      throw FoundationModelsProvider.makeError(code: 10, message: "Temporary model failure")
    }
    do {
      _ = try await provider.transcribeScreenshots(
        screenshots, batchStartTime: screenshots[0].capturedDate, batchId: 7)
      XCTFail("The existing backup path needs an error after both Apple attempts fail")
    } catch let error as NSError {
      XCTAssertEqual(error.domain, FoundationModelsProvider.errorDomain)
      XCTAssertEqual(error.code, 10)
    }
    XCTAssertEqual(calls, 2)
  }

  func testSelectedMissingFrameFailsBothAttemptsBeforeModelInference() async throws {
    let screenshots = try makeScreenshots(count: 2)
    try FileManager.default.removeItem(at: screenshots[1].fileURL)
    var attempts = 0
    var modelCalls = 0
    let provider = FoundationModelsProvider(logsCalls: false, modelAvailability: {
      attempts += 1
      return .available
    }) { _, _, _, _ in
      modelCalls += 1
      return .init(app: "Xcode", activity: "Read code", evidence: "Swift file")
    }
    do {
      _ = try await provider.transcribeScreenshots(
        screenshots, batchStartTime: screenshots[0].capturedDate, batchId: 7)
      XCTFail("A missing selected frame must not become a partially successful transcription")
    } catch let error as NSError {
      XCTAssertEqual(error.domain, FoundationModelsProvider.errorDomain)
      XCTAssertEqual(error.code, 4)
    }
    XCTAssertEqual(attempts, 2)
    XCTAssertEqual(modelCalls, 0)
  }

  func testPartialModelRefusalDoesNotReturnSuccessfulObservations() async throws {
    let screenshots = try makeScreenshots(count: 2)
    let failures: [LanguageModelError] = [
      .refusal(.init(explanation: "Unavailable", debugDescription: "Test refusal")),
      .guardrailViolation(.init(debugDescription: "Test guardrail")),
    ]
    for failure in failures {
      var calls = 0
      let provider = FoundationModelsProvider(logsCalls: false, modelAvailability: { .available }) {
        _, _, _, _ in
        calls += 1
        if calls.isMultiple(of: 2) { throw failure }
        return .init(app: "Xcode", activity: "Read code", evidence: "Swift file")
      }
      do {
        _ = try await provider.transcribeScreenshots(
          screenshots, batchStartTime: screenshots[0].capturedDate, batchId: 7)
        XCTFail("Refusal after a successful frame must still fail the transcription")
      } catch let error as NSError {
        XCTAssertEqual(error.domain, FoundationModelsProvider.errorDomain)
        XCTAssertEqual(error.code, 5)
      }
      XCTAssertEqual(calls, 4)
    }
  }

  func testTranscriptionCancellationDoesNotRetryOrBecomeProviderFailure() async throws {
    let screenshots = try makeScreenshots(count: 1)
    let cancellations: [Error] = [CancellationError(),
      NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)]
    for cancellation in cancellations {
      var calls = 0
      let provider = FoundationModelsProvider(logsCalls: false, modelAvailability: { .available }) {
        _, _, _, _ in
        calls += 1
        throw cancellation
      }
      do {
        _ = try await provider.transcribeScreenshots(
          screenshots, batchStartTime: screenshots[0].capturedDate, batchId: 7)
        XCTFail("Expected cancellation")
      } catch {
        XCTAssertFalse(shouldAttemptProviderBackup(after: error))
      }
      XCTAssertEqual(calls, 1)
    }
  }

  func testUnselectedMissingFrameDoesNotFailOrRetrySuccessfulTranscription() async throws {
    let screenshots = try makeScreenshots(count: 17)
    // Index 8 lies between the 16 evenly spaced samples and is intentionally not selected.
    try FileManager.default.removeItem(at: screenshots[8].fileURL)
    var calls = 0
    let provider = FoundationModelsProvider(logsCalls: false, modelAvailability: { .available }) {
      _, _, _, _ in
      calls += 1
      return .init(app: "Xcode", activity: "Read code", evidence: "Swift file")
    }
    let result = try await provider.transcribeScreenshots(
      screenshots, batchStartTime: screenshots[0].capturedDate, batchId: 7)
    XCTAssertEqual(calls, 16)
    XCTAssertEqual(result.observations.count, 16)
  }

  func testInferenceDeadlineCancelsCallAndReleasesQueue() async throws {
    let gate = FoundationModelsInferenceGate()
    do {
      _ = try await gate.run(timeout: .zero) {
        try await Task.sleep(for: .seconds(60))
        return 1
      }
      XCTFail("Expected a deadline failure")
    } catch let error as NSError {
      XCTAssertEqual(error.domain, FoundationModelsProvider.errorDomain)
      XCTAssertEqual(error.code, 10)
    }
    let next = try await gate.run { 2 }
    XCTAssertEqual(next, 2)
  }

  func testSequenceRejectsOverlappingAndZeroLengthCards() {
    func card(_ start: String, _ end: String) -> ActivityCardData {
      ActivityCardData(startTime: start, endTime: end, category: "Work", subcategory: "",
        title: "Activity", summary: "", detailedSummary: "", distractions: nil, appSites: nil)
    }
    let provider = FoundationModelsProvider(logsCalls: false)
    XCTAssertFalse(provider.validateCardSequence([card("9:20 PM", "9:35 PM"), card("9:25 PM", "9:40 PM")]).isValid)
    XCTAssertFalse(provider.validateCardSequence([card("9:20 PM", "9:20 PM")]).isValid)
    XCTAssertFalse(provider.validateCardSequence([card("invalid", "9:20 PM")]).isValid)
    XCTAssertTrue(provider.validateCardSequence([card("11:50 PM", "12:05 AM"), card("12:05 AM", "12:20 AM")]).isValid)
  }

  func testSampledIndicesKeepsFirstAndLastAndCapsAt16() {
    let indices = FoundationModelsProvider.sampledIndices(count: 91, maxFrames: 16)
    XCTAssertEqual(indices.count, 16)
    XCTAssertEqual(indices.first, 0)
    XCTAssertEqual(indices.last, 90)
    XCTAssertTrue(zip(indices, indices.dropFirst()).allSatisfy { $0 < $1 })
  }

  func testSampledIndicesReturnsAllWhenCountAtOrBelow16() {
    XCTAssertEqual(
      FoundationModelsProvider.sampledIndices(count: 16, maxFrames: 16),
      Array(0..<16)
    )
    XCTAssertEqual(
      FoundationModelsProvider.sampledIndices(count: 5, maxFrames: 16),
      [0, 1, 2, 3, 4]
    )
    XCTAssertEqual(FoundationModelsProvider.sampledIndices(count: 0, maxFrames: 16), [])
  }

  func testObservationTextOmitsEvidenceSuffixWhenEmpty() {
    XCTAssertEqual(
      FoundationModelsProvider.observationText(
        app: "Xcode", activity: "editing a Swift file", evidence: ""
      ),
      "Xcode: editing a Swift file"
    )
    XCTAssertEqual(
      FoundationModelsProvider.observationText(
        app: "Xcode", activity: "editing a Swift file", evidence: "   "
      ),
      "Xcode: editing a Swift file"
    )
    XCTAssertEqual(
      FoundationModelsProvider.observationText(
        app: "Xcode", activity: "editing a Swift file", evidence: "file name LLMService.swift"
      ),
      "Xcode: editing a Swift file Evidence: file name LLMService.swift"
    )
  }

  func testObservationsUseNextFrameAsEndAndTenSecondsForLast() {
    let observations = FoundationModelsProvider.observations(
      from: [(100, "a"), (160, "b"), (250, "c")],
      batchId: 7
    )
    XCTAssertEqual(observations.map(\.startTs), [100, 160, 250])
    XCTAssertEqual(observations.map(\.endTs), [160, 250, 260])
    XCTAssertTrue(observations.allSatisfy { $0.batchId == 7 })
    XCTAssertTrue(observations.allSatisfy { $0.llmModel == "system-language-model" })
    XCTAssertTrue(observations.allSatisfy { $0.metadata == nil })
  }

  func testErrorMessagesAvoidClassifierSubstrings() {
    let representativeDetail: [Int: String] = [
      1: "this Mac isn't eligible",
      8: "timeout",
    ]
    let forbidden = [
      "context size has been exceeded",
      "cancelled",
      "timed out",
      "internal error",
      "quota exceeded",
      "failed to parse",
      "missing coverage",
      "failed to load",
      "no llm provider configured",
    ]

    for code in 1...9 {
      let message = FoundationModelsProvider.errorMessage(
        code: code,
        detail: representativeDetail[code] ?? ""
      ).lowercased()
      XCTAssertFalse(message.isEmpty)
      for substring in forbidden {
        XCTAssertFalse(message.contains(substring), "code \(code): \(substring)")
      }
    }

    let error = FoundationModelsProvider.makeError(
      code: 3,
      message: FoundationModelsProvider.errorMessage(code: 3, detail: "")
    )
    XCTAssertEqual(error.domain, "FoundationModelsProvider")
    XCTAssertEqual(
      error.localizedDescription,
      FoundationModelsProvider.errorMessage(code: 3, detail: "")
    )
  }

  func testAvailabilityMappingCoversAllUnavailableReasons() {
    XCTAssertEqual(
      FoundationModelsProvider.availability(from: .available),
      .available
    )
    XCTAssertEqual(
      FoundationModelsProvider.availability(from: .unavailable(.deviceNotEligible)),
      .deviceNotEligible
    )
    XCTAssertEqual(
      FoundationModelsProvider.availability(from: .unavailable(.appleIntelligenceNotEnabled)),
      .appleIntelligenceNotEnabled
    )
    XCTAssertEqual(
      FoundationModelsProvider.availability(from: .unavailable(.modelNotReady)),
      .modelNotReady
    )
  }

  func testLiveTranscribeProducesObservations() async throws {
    guard ProcessInfo.processInfo.environment["DAYFLOW_FM_LIVE"] == "1" else {
      throw XCTSkip("set TEST_RUNNER_DAYFLOW_FM_LIVE=1 to run")
    }
    guard #available(macOS 27.0, *) else {
      throw XCTSkip("Foundation Models live path needs macOS 27.")
    }

    let recordingsURL = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    )[0].appendingPathComponent("Dayflow/recordings", isDirectory: true)
    let files = try FileManager.default.contentsOfDirectory(atPath: recordingsURL.path)
      .filter { $0.hasSuffix(".jpg") }
      .sorted()
      .prefix(2)
    guard files.count == 2 else {
      throw XCTSkip("Need two local JPEG recordings to run the live test.")
    }

    let screenshots = files.enumerated().map { index, file in
      Screenshot(
        id: Int64(index + 1),
        capturedAt: 1_000_000 + index * 10,
        filePath: recordingsURL.appendingPathComponent(file).path,
        fileSize: nil,
        idleSecondsAtCapture: nil,
        isDeleted: false,
        frameIndex: nil
      )
    }
    let provider = FoundationModelsProvider(logsCalls: false)
    let result = try await provider.transcribeScreenshots(
      screenshots,
      batchStartTime: Date(timeIntervalSince1970: 1_000_000),
      batchId: nil
    )
    XCTAssertEqual(result.observations.count, 2)
    XCTAssertTrue(result.observations.allSatisfy { !$0.observation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    XCTAssertTrue(result.observations.allSatisfy { $0.observation.contains(": ") })
    XCTAssertEqual(result.observations[0].endTs, 1_000_010)
    XCTAssertEqual(result.observations[1].endTs, 1_000_020)
    XCTAssertTrue(result.log.input?.hasPrefix("frames=2/2") == true)
  }
}
