import XCTest

@testable import Dayflow

@MainActor
final class FoundationModelsSettingsTests: XCTestCase {
  private let defaultKeys = [
    "llmLocalEngine",
    "llmLocalBaseURL",
    "llmLocalModelId",
    "llmLocalAPIKey",
    "localSetupComplete",
    "chatGPTPromptOverrides",
    "claudePromptOverrides",
    "dayflowProviderEndpointV2",
    "chatgptSetupComplete",
    "claudeSetupComplete",
    "geminiSelectedModel_v3",
    "geminiSelectedModel_v4",
    LLMProviderRoutingStore.storageKey,
  ]

  private var savedDefaults: [String: Any?] = [:]

  override func setUp() {
    super.setUp()
    savedDefaults = Dictionary(
      uniqueKeysWithValues: defaultKeys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
    )
    defaultKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
  }

  override func tearDown() {
    defaultKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    for (key, value) in savedDefaults {
      if let value {
        UserDefaults.standard.set(value, forKey: key)
      }
    }
    savedDefaults = [:]
    super.tearDown()
  }

  private func seedRouting(primary: LLMProviderID, secondary: LLMProviderID? = nil) throws {
    try LLMProviderRoutingStore.save(
      LLMProviderRouting(primary: primary, secondary: secondary),
      to: .standard
    )
  }

  func testRequestPrimaryFoundationModelsWithSecondaryDefersAndSetsFlag() throws {
    try seedRouting(primary: .gemini, secondary: .local)
    let viewModel = ProvidersSettingsViewModel()
    viewModel.loadRouting()

    viewModel.requestAssignPrimaryProvider(.foundationModels)

    XCTAssertEqual(viewModel.primaryRoutingProviderId, .gemini)
    XCTAssertEqual(viewModel.secondaryRoutingProviderId, .local)
    XCTAssertTrue(viewModel.showKeepBackupConfirm)
    XCTAssertEqual(viewModel.pendingPrimarySelection, .foundationModels)
  }

  func testConfirmRemoveBackupAssignsPrimaryAndClearsSecondary() throws {
    try XCTSkipUnless(
      FoundationModelsSupport.currentAvailability() == .available,
      "Requires macOS 27 with Apple Intelligence enabled"
    )
    try seedRouting(primary: .gemini, secondary: .local)
    let viewModel = ProvidersSettingsViewModel()
    viewModel.loadRouting()
    viewModel.requestAssignPrimaryProvider(.foundationModels)

    viewModel.confirmRemoveBackup()

    XCTAssertEqual(viewModel.primaryRoutingProviderId, .foundationModels)
    XCTAssertNil(viewModel.secondaryRoutingProviderId)
    XCTAssertNil(viewModel.pendingPrimarySelection)
  }

  func testRequestPrimaryFoundationModelsWithoutSecondaryAssignsImmediately() throws {
    try XCTSkipUnless(
      FoundationModelsSupport.currentAvailability() == .available,
      "Requires macOS 27 with Apple Intelligence enabled"
    )
    try seedRouting(primary: .gemini)
    let viewModel = ProvidersSettingsViewModel()
    viewModel.loadRouting()

    viewModel.requestAssignPrimaryProvider(.foundationModels)

    XCTAssertEqual(viewModel.primaryRoutingProviderId, .foundationModels)
    XCTAssertFalse(viewModel.showKeepBackupConfirm)
    XCTAssertNil(viewModel.pendingPrimarySelection)
  }

  func testRequestSecondaryWhenPrimaryIsFoundationModelsDefers() throws {
    try seedRouting(primary: .foundationModels)
    let viewModel = ProvidersSettingsViewModel()
    viewModel.loadRouting()

    viewModel.requestAssignSecondaryProvider(.gemini)

    XCTAssertEqual(viewModel.primaryRoutingProviderId, .foundationModels)
    XCTAssertNil(viewModel.secondaryRoutingProviderId)
    XCTAssertTrue(viewModel.showBackupDataConfirm)
    XCTAssertEqual(viewModel.pendingSecondarySelection, .gemini)
  }

  func testSetupCompletionForFoundationModelsWithSecondaryDefersConfirmation() throws {
    try seedRouting(primary: .gemini, secondary: .local)
    let viewModel = ProvidersSettingsViewModel()
    viewModel.loadRouting()
    viewModel.beginProviderSetup(.foundationModels, role: .primary)

    let succeeded = viewModel.handleProviderSetupCompletion(.foundationModels)

    XCTAssertTrue(succeeded)
    XCTAssertEqual(viewModel.primaryRoutingProviderId, .gemini)
    XCTAssertEqual(viewModel.secondaryRoutingProviderId, .local)
    XCTAssertTrue(viewModel.showKeepBackupConfirm)
    XCTAssertEqual(viewModel.pendingPrimarySelection, .foundationModels)
  }
}
