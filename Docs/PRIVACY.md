# Privacy model

Beacon's default path is local and Accessibility-first. No account, API key, screenshot, or external model is required. When Screen Recording is granted, OCR and control-shape analysis still run locally by default.

## Capture rules

- Capture starts only after Option + Space, a visible menu action, or an explicit Developer Inspector refresh.
- Screen Recording is optional for the default grounder.
- Applications in the exclusion list never produce screenshots and are forced onto the local deterministic provider.
- Password values are removed during Accessibility extraction.
- Secure text fields and OCR-detected emails, phone numbers, credit cards, and common API-key formats are masked locally before a screenshot is stored as the current privacy preview.
- Temporary verification frames stay in memory and are never sent to a model.
- Excluded applications are removed from ScreenCaptureKit at capture time, including when their windows share a display with the active app.
- Overlay and prompt windows are rendered locally and never become model drawing input.

## Cloud boundary

Cloud processing has a separate opt-in and is disabled by default. The OpenAI adapter sends the user's question plus bounded, privacy-filtered application, window, accessible-control, visual-candidate, and mark metadata. API keys are kept in the macOS Keychain, not UserDefaults or repository files, and can be removed again from Model settings. Responses API requests set `store` to false.

Images require a second, independent **Allow the redacted visual preview** opt-in. When enabled, Beacon redacts the screenshot locally, draws the validated Set-of-Marks badges over that redacted image, and exposes the exact outbound image under **Privacy**. Only that displayed numbered image becomes eligible for the OpenAI request. The toggle is off by default, and application exclusions always override it.

The model screen exposes one provider choice instead of quality presets. Selecting OpenAI does not grant cloud access: the separate cloud-processing toggle remains the authoritative consent boundary, and Beacon falls back to its local Accessibility matcher while that toggle is off.

The optional Developer Inspector is hidden by default. When enabled, it displays local perception results, redaction counts, intent classification, and the exact bounded text context provided to the configured reasoning model. The normal Privacy screen exposes the outbound image so visual consent does not depend on enabling developer tools.

## Known limits

- Pattern-based OCR redaction can produce false positives or miss unusual formats; exclude sensitive apps when certainty matters.
- Accessibility labels can themselves contain sensitive text. Exclude sensitive apps and keep cloud processing disabled when this matters.
- Enabling redacted visual previews shares visible, non-redacted screen content with the configured OpenAI account. Review the exact preview and the provider's current retention policy before enabling it.
- ScreenCaptureKit permission is controlled by macOS and associated with the packaged app identity.
- Ad-hoc development builds are not a production trust boundary. Release builds should be hardened, signed, notarized, and independently audited.

## Reporting

Do not include captured screens, accessibility dumps, API keys, or personal data in public bug reports. Reproduce grounding bugs with the smallest safe fixture or a synthetic application.
