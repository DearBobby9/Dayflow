import XCTest

@testable import Dayflow

final class FoundationModelsWiringTests: XCTestCase {
  private var suiteNames: [String] = []

  override func tearDown() {
    for suiteName in suiteNames {
      UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
    suiteNames.removeAll()
    super.tearDown()
  }

  private func makeDefaults() throws -> UserDefaults {
    let suiteName = "FoundationModelsWiringTests.\(UUID().uuidString)"
    suiteNames.append(suiteName)
    return try XCTUnwrap(UserDefaults(suiteName: suiteName))
  }

  func testFoundationModelsRawValueAndLabelsAreFrozen() {
    XCTAssertEqual(LLMProviderID.foundationModels.rawValue, "foundation_models")
    XCTAssertEqual(LLMProviderID.foundationModels.analyticsName, "apple_foundation_models")
    XCTAssertEqual(LLMProviderID.foundationModels.providerLabel, "foundation_models")
  }

  func testRoutingRoundTripPersistsFoundationModelsPrimary() throws {
    let defaults = try makeDefaults()
    try LLMProviderRoutingStore.save(
      LLMProviderRouting(primary: .foundationModels),
      to: defaults
    )
    let stored = try XCTUnwrap(defaults.data(forKey: LLMProviderRoutingStore.storageKey))
    let json = try XCTUnwrap(String(data: stored, encoding: .utf8))
    XCTAssertTrue(json.contains("\"foundation_models\""))

    let loaded = try LLMProviderRoutingStore.load(from: defaults)
    XCTAssertEqual(loaded.primary, .foundationModels)
    XCTAssertNil(loaded.secondary)
  }

  func testShouldAttemptProviderBackupIsFalseForCancellation() {
    XCTAssertFalse(shouldAttemptProviderBackup(after: CancellationError()))
    XCTAssertFalse(
      shouldAttemptProviderBackup(
        after: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
      )
    )
    XCTAssertTrue(
      shouldAttemptProviderBackup(
        after: NSError(
          domain: "FoundationModelsProvider",
          code: 8,
          userInfo: [NSLocalizedDescriptionKey: "The on-device model failed (rateLimited)."]
        )
      )
    )
    XCTAssertTrue(
      shouldAttemptProviderBackup(
        after: NSError(domain: "FoundationModelsProvider", code: NSUserCancelledError)
      )
    )
  }

  func testClassifierMapsFoundationModelsUnavailableMessages() {
    let disabled = NSError(
      domain: "FoundationModelsProvider",
      code: 1,
      userInfo: [
        NSLocalizedDescriptionKey:
          "Apple Intelligence isn't available: it isn't enabled in System Settings."
      ]
    )
    let oldMac = NSError(
      domain: "FoundationModelsProvider",
      code: 2,
      userInfo: [
        NSLocalizedDescriptionKey: "Apple Foundation Models needs macOS 27 or later."
      ]
    )

    XCTAssertEqual(
      TimelineFailureClassifier.classify(disabled).kind,
      .foundationModelsUnavailable
    )
    XCTAssertEqual(
      TimelineFailureClassifier.classify(oldMac).kind,
      .foundationModelsUnavailable
    )
    XCTAssertEqual(
      TimelineFailureClassifier.classify(disabled)
        .toastContent(fallbackProviderLabel: "foundation_models")?.title,
      "Apple Intelligence isn't available"
    )
  }

  func testClassifierDoesNotMisrouteProviderErrorMessages() {
    let cases: [(Int, String)] = [
      (3, "The on-device model's context budget was exceeded."),
      (4, "None of the screenshots in this batch could be decoded."),
      (5, "The on-device model declined to describe this content."),
      (6, "The on-device model produced cards that didn't pass validation."),
      (7, "The on-device model returned no observations for this batch."),
      (9, "The on-device model reported its context limit was reached."),
    ]
    let forbidden: [TimelineFailureKind] = [
      .localModelMissing,
      .transient,
      .modelFlaky,
      .foundationModelsUnavailable,
    ]

    for (code, message) in cases {
      let error = NSError(
        domain: "FoundationModelsProvider",
        code: code,
        userInfo: [NSLocalizedDescriptionKey: message]
      )
      let kind = TimelineFailureClassifier.classify(error).kind
      for forbiddenKind in forbidden {
        XCTAssertNotEqual(kind, forbiddenKind, "code \(code) was classified as \(forbiddenKind)")
      }
    }
  }
}
