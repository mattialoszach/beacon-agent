# Privacy model

Beacon's default path is local and Accessibility-first. No account, API key, screenshot, or external model is required. When Screen Recording is granted, OCR and control-shape analysis still run locally by default.

Beacon requests only the permissions used by its current features: Accessibility and optional Screen Recording. It does not request microphone access.

## Capture rules

- Capture starts only after Option + Space, a visible menu action, or an explicit Developer Inspector refresh.
- Screen Recording is optional for the default grounder.
- Applications in the exclusion list never produce screenshots and are forced onto the local deterministic provider.
- Notification Center is always excluded from capture. Banners are drawn by that process rather than by the application that posted them, so an excluded application's alert would otherwise appear in a capture.
- Password values are removed during Accessibility extraction.
- Secure text fields and OCR-detected emails, phone numbers, credit cards, common API-key formats, and complete PEM private-key blocks are masked locally before a screenshot is stored as the current privacy preview. PEM handling carries sensitivity from the `BEGIN` line through the matching `END` line and removes derived shape labels that copied any key-body text. Secure fields in the application's other visible windows are masked too, because the capture covers the whole display.
- Sensitive-text patterns are matched against candidate substrings, so a card or phone number sharing an OCR line with unrelated digits is still masked.
- Change detection compares a lightweight in-memory luminance sample captured before redaction with a new sample captured the same way. The redacted preview is only a lookup key, so redaction masks cannot be mistaken for interface changes. Text recognition and shape analysis run only once that comparison shows the screen actually changed.
- Temporary freshness and verification frames stay in memory and are never sent to a model.
- Excluded applications are removed from ScreenCaptureKit at capture time, including when their windows share a display with the active app.
- Overlay and prompt windows are rendered locally and never become model drawing input.
- Local analysis captures are resolution-bounded in memory; the Privacy screen still shows the exact redacted image eligible for a consented visual request.
- Pause Screen Access cancels active guidance and blocks inspector capture as well as new prompts. Changing cloud consent or exclusions invalidates pending work and clears retained scene and image previews. An already-running OS capture may finish, but its result is discarded after cancellation.
- Display configuration changes cancel active work and clear retained scene/image context.
- Ambiguous outcomes require explicit confirmation. Waiting for confirmation uses a bounded Accessibility-only observer; no screenshots or model requests are made during that wait.
- Verification images are discarded before preparing another model request. A following guide step obtains a separate reasoning capture if visual context is needed.
- Active requests can follow the user into another app or window. Beacon clears the previous visual context and reapplies capture exclusions and provider selection to the new scene; excluded destinations still receive no screenshots or external model requests. A focus change does not confirm that the previous action succeeded.

## Cloud boundary

Cloud processing has a separate opt-in and is disabled by default. The OpenAI adapter sends the user's question plus bounded, privacy-filtered application, window, accessible-control, visual-candidate, and mark metadata. Checkbox, radio-button, and format-popup values may be included for precise outcome reasoning; they pass through the same bounded sensitive-text filter. Text-field values are not added as a separate prompt field. API keys are kept in the macOS Keychain, not UserDefaults or repository files, and can be removed again from Model settings. Responses API requests set `store` to false.

The prompt budget includes the question, scene header, and completed-step history. Completed instructions and target labels pass through sensitive-text filtering before entering subsequent prompts. Screenshot masks cover complete boundary pixels to avoid partially revealing text at fractional coordinates.

Images require a second, independent **Allow the redacted visual preview** opt-in. When enabled, Beacon redacts the screenshot locally, draws the validated Set-of-Marks badges over that redacted image, and exposes the exact outbound image under **Privacy**. Only that displayed numbered image becomes eligible for the OpenAI request. The toggle is off by default, and application exclusions always override it.

The model screen exposes one provider choice instead of ambiguous quality presets. OpenAI users choose from a bounded list of supported models rather than entering an arbitrary model identifier. Selecting OpenAI does not grant cloud access: the separate cloud-processing toggle remains the authoritative consent boundary, and Beacon falls back to its local Accessibility matcher while that toggle is off.

The optional Developer Inspector is hidden by default. When enabled, it displays local perception results, redaction counts, intent classification, and the exact bounded text context that was prepared for the configured reasoning model. That context is the text a request would carry; it is built and shown even when the request is answered locally without calling a model. The normal Privacy screen exposes the outbound image so visual consent does not depend on enabling developer tools.

API keys are read from Keychain for requests. The key field in Model settings is an editable draft: a request uses the saved key, never an unsaved edit. Keychain mutations are serialized and each save snapshots the submitted draft before waiting, so a queued operation cannot silently replace it with an older value.

## Known limits

- Pattern-based OCR redaction can produce false positives or miss unusual formats; exclude sensitive apps when certainty matters. Detection deliberately errs toward masking, so ordinary text that looks like a card or phone number can be hidden from local matching.
- Accessibility labels can themselves contain sensitive text. Exclude sensitive apps and keep cloud processing disabled when this matters.
- Enabling redacted visual previews shares visible, non-redacted screen content with the configured OpenAI account. Review the exact preview and the provider's current retention policy before enabling it.
- ScreenCaptureKit permission is controlled by macOS and associated with the packaged app identity.
- Ad-hoc development builds are not a production trust boundary. Release builds should be hardened, signed, notarized, and independently audited.

## Reporting

Do not include captured screens, accessibility dumps, API keys, or personal data in public bug reports. Reproduce grounding bugs with the smallest safe fixture or a synthetic application.
