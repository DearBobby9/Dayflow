# Apple Foundation Models

Apple Foundation Models can generate Dayflow's Timeline on your Mac without an API key or a local model server. Daily and Chat use their own provider settings.

## Requirements and setup

This provider requires macOS 27 or later, an Apple Intelligence eligible Mac, and an available on-device model. Building Dayflow from source requires Xcode 27 or later because screenshot understanding uses the Foundation Models image APIs. The framework is weak-linked and the app deployment target remains macOS 14.

Choose **Apple on-device** during onboarding, or **Apple** in Settings → Providers. Check availability before completing setup. If Apple Intelligence is disabled or its model is still downloading, enable it in System Settings and use **Refresh status** in Dayflow when it is ready.

## Data and backup behavior

With Apple selected and no backup configured, Timeline inference runs on device. Choosing Apple for Timeline does not change the Daily or Chat provider.

Dayflow asks before retaining or adding a backup to an Apple primary provider, including provider role swaps. If you keep a backup, failed Apple processing can send screenshots and observations to that provider. Cancelling an operation does not trigger the backup. Passive provider status checks read existing Keychain credentials without prompting for access.

## Timeline generation

The provider uses the existing screenshot, observation, activity-card, and persistence paths:

1. Sample up to 16 screenshots across a batch, retaining the first and last frames. Decode the selected frames and downscale full images to 1280 pixels on the longest edge.
2. Copy the top 12% of each image into an independent buffer and recognize header text. Supply the full image, header image, and OCR text to the on-device model as untrusted screen evidence.
3. Generate a short observation for each sampled frame. A failed transcription gets one complete retry; partial observations from a failed attempt are discarded.
4. Generate the current batch's summary, category, and title. Code determines the card interval from observations and the capture cutoff.
5. Optionally merge with the preceding non-idle card when it describes the same task. The preceding card must be under 40 minutes, the gap at most 5 minutes, and the combined interval at most 60 minutes. A failed optional merge keeps the separate current card.
6. Preserve existing card prefixes and suffixes when reprocessing an overlapping interval, then validate the resulting sequence before replacement.

Model calls share one inference gate. Each request uses a short-lived session, and text-generation inputs are checked against a fraction of the model's context budget. Timeline validation uses the existing absolute-time resolver, including midnight and daylight-saving transitions.

## Limitations

- A batch currently produces one new activity card. Mixed tasks within that batch may receive a broad summary and one majority category; a merged card keeps the preceding card's category.
- Apple can refuse some screen content. Without a configured backup, the batch produces a processing-failure notice instead of a semantic activity card.
- Inference deadlines use cooperative task cancellation. They cannot force an underlying model request to stop immediately if it does not respond to cancellation.
- Card replacement can assign an earlier interval to a later processing batch. Assess coverage using active cards that overlap the source interval, including replacement cards from later batches.

## Validation

The focused regression suites are:

| Suite | Behavior covered |
| --- | --- |
| `FoundationModelsProviderTests` | Sampling, transcription retry, missing/refused frames, cancellation, availability, and interval validation |
| `FoundationModelsLocalCardTests` | Capture cutoff, idle cards, prefix/suffix preservation, midnight merges, merge limits, and optional-merge failure |
| `FoundationModelsHeaderOCRTests` | Header pixels and release of the full screenshot buffer |
| `FoundationModelsSettingsTests` | Onboarding readiness, backup confirmation, role swaps, and separate Daily/Chat selections |
| `FoundationModelsWiringTests` | Routing persistence, cancellation fallback rules, and failure classification |
| `LLMProviderRoutingTests` | Existing routing and migration behavior |
| `ProvidersSettingsViewModelTests` | Existing provider setup and assignment behavior |

Run these suites on macOS 27 using the Dayflow scheme. Run the settings and routing suites serially because they temporarily use and restore standard preferences. Availability-dependent cases can skip on an ineligible Mac.

The optional `DAYFLOW_FM_LIVE_CARDS=1` check runs card generation against synthetic observations. When launching it through `xcodebuild`, use `TEST_RUNNER_DAYFLOW_FM_LIVE_CARDS=1`. Transcription regression tests create temporary fixture images and inject model responses, so they do not depend on personal recordings or a production database.

Automated assertions establish contracts and recovery behavior; they do not measure overall semantic accuracy or application energy use.
