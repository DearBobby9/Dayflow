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
    "dailyRecapProvider_v1",
    "dashboardChatProvider",
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

  private func seedLocalProvider() {
    UserDefaults.standard.set("http://localhost:11434", forKey: "llmLocalBaseURL")
    UserDefaults.standard.set("test-vision-model", forKey: "llmLocalModelId")
  }

  func testAppleSetupRequiresReadinessCheckAfterIntroduction() {
    let state = ProviderSetupState()
    state.configureSteps(for: .foundationModels)

    state.goNext()

    XCTAssertFalse(state.canContinue, "Apple setup must check readiness before reaching completion")
  }

  func testAppleSetupHandlesReadinessLossAndRecovery() {
    let state = ProviderSetupState()
    state.configureSteps(for: .foundationModels)
    state.goNext()

    state.refreshFoundationModelsAvailability(.modelNotReady)
    XCTAssertFalse(state.canContinue)

    state.refreshFoundationModelsAvailability(.available)
    XCTAssertTrue(state.canContinue)

    state.refreshFoundationModelsAvailability(.appleIntelligenceNotEnabled)
    XCTAssertFalse(state.canContinue)
    XCTAssertFalse(state.testSuccessful)
  }

  func testSwitchingTimelineToApplePreservesDailyAndChatSelections() throws {
    try seedRouting(primary: .gemini)
    DailyRecapProvider.claude.save()
    UserDefaults.standard.set(DashboardChatProvider.codex.rawValue, forKey: "dashboardChatProvider")
    let viewModel = ProvidersSettingsViewModel()
    viewModel.loadRouting()

    XCTAssertTrue(viewModel.assignPrimaryProvider(.foundationModels, requiresReadinessCheck: false))

    XCTAssertEqual(DailyRecapProvider.load(), .claude)
    XCTAssertEqual(UserDefaults.standard.string(forKey: "dashboardChatProvider"), "codex")
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
    XCTAssertFalse(viewModel.showKeepBackupConfirm)
    XCTAssertEqual(viewModel.pendingPrimarySelection, .foundationModels)

    viewModel.cancelProviderSetup()
    viewModel.presentPendingAppleBackupConfirmation()

    XCTAssertTrue(viewModel.showKeepBackupConfirm)
  }

  func testSecondarySetupWithAppleDefersRoutingUntilConfirmed() throws {
    try seedRouting(primary: .foundationModels)
    let viewModel = ProvidersSettingsViewModel()
    viewModel.loadRouting()
    viewModel.beginProviderSetup(.local, role: .secondary)
    seedLocalProvider()

    XCTAssertTrue(viewModel.handleProviderSetupCompletion(.local))

    XCTAssertNil(viewModel.secondaryRoutingProviderId)
    XCTAssertNil(try LLMProviderRoutingStore.load().secondary)
    XCTAssertFalse(viewModel.showBackupDataConfirm)
    XCTAssertEqual(viewModel.pendingSecondarySelection, .local)

    viewModel.cancelProviderSetup()
    viewModel.presentPendingAppleBackupConfirmation()
    XCTAssertTrue(viewModel.showBackupDataConfirm)
    viewModel.confirmAssignSecondary()

    XCTAssertEqual(viewModel.primaryRoutingProviderId, .foundationModels)
    XCTAssertEqual(try LLMProviderRoutingStore.load().secondary, .local)
  }

  func testCancellingSecondarySetupConfirmationPreservesAppleOnlyRouting() throws {
    try seedRouting(primary: .foundationModels)
    let viewModel = ProvidersSettingsViewModel()
    viewModel.loadRouting()
    viewModel.beginProviderSetup(.local, role: .secondary)
    XCTAssertTrue(viewModel.handleProviderSetupCompletion(.local))

    viewModel.cancelProviderSetup()
    viewModel.presentPendingAppleBackupConfirmation()
    viewModel.cancelPendingSelection()

    XCTAssertEqual(try LLMProviderRoutingStore.load().primary, .foundationModels)
    XCTAssertNil(try LLMProviderRoutingStore.load().secondary)
    XCTAssertNil(viewModel.pendingSecondarySelection)
  }

  func testSecondaryRoleSwapToAppleDefersUntilConfirmed() throws {
    try seedRouting(primary: .local, secondary: .foundationModels)
    seedLocalProvider()
    let viewModel = ProvidersSettingsViewModel()
    viewModel.loadRouting()

    viewModel.requestAssignSecondaryProvider(.local)

    XCTAssertEqual(try LLMProviderRoutingStore.load().primary, .local)
    XCTAssertEqual(try LLMProviderRoutingStore.load().secondary, .foundationModels)
    XCTAssertTrue(viewModel.showBackupDataConfirm)
    XCTAssertEqual(viewModel.pendingSecondarySelection, .local)

    viewModel.confirmAssignSecondary()

    XCTAssertEqual(try LLMProviderRoutingStore.load().primary, .foundationModels)
    XCTAssertEqual(try LLMProviderRoutingStore.load().secondary, .local)
  }

  func testSecondarySetupWithoutAppleKeepsImmediateAssignment() throws {
    try seedRouting(primary: .chatGPT)
    let viewModel = ProvidersSettingsViewModel()
    viewModel.loadRouting()
    viewModel.beginProviderSetup(.local, role: .secondary)

    XCTAssertTrue(viewModel.handleProviderSetupCompletion(.local))

    XCTAssertEqual(try LLMProviderRoutingStore.load().primary, .chatGPT)
    XCTAssertEqual(try LLMProviderRoutingStore.load().secondary, .local)
    XCTAssertFalse(viewModel.showBackupDataConfirm)
  }
}
