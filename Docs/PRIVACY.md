# Privacy model

Beacon's default path is local and accessibility-only. No account, API key, screenshot, or external model is required.

## Capture rules

- Capture starts only after Option + Space, a visible menu action, or an explicit Developer Inspector refresh.
- Screen Recording is optional for the default grounder.
- Applications in the exclusion list never produce screenshots and are forced onto the local deterministic provider.
- Password values are removed during Accessibility extraction.
- Secure text fields and OCR-detected emails, phone numbers, credit cards, and common API-key formats are masked locally before a screenshot is stored as the current privacy preview.
- Excluded applications are removed from ScreenCaptureKit at capture time, including when their windows share a display with the active app.
- Overlay and prompt windows are rendered locally and never become model drawing input.

## Cloud boundary

Cloud processing has a separate opt-in and is disabled by default. The current OpenAI adapter sends the user's question plus structured application, window, and accessible-control metadata. It does **not** attach the screenshot. API keys are kept in the macOS Keychain, not UserDefaults or repository files.

The model screen exposes one provider choice instead of quality presets. Selecting OpenAI does not grant cloud access: the separate cloud-processing toggle remains the authoritative consent boundary, and Beacon falls back to its local Accessibility matcher while that toggle is off.

The optional Developer Inspector is hidden by default. When enabled, it displays the local redacted screenshot, reports hidden regions, and separately shows the exact bounded text context provided to the configured reasoning model. Because the current cloud adapter is text-only, the image does not leave the machine.

## Known limits

- Pattern-based OCR redaction can produce false positives or miss unusual formats; exclude sensitive apps when certainty matters.
- Accessibility labels can themselves contain sensitive text. Exclude sensitive apps and keep cloud processing disabled when this matters.
- ScreenCaptureKit permission is controlled by macOS and associated with the packaged app identity.
- Ad-hoc development builds are not a production trust boundary. Release builds should be hardened, signed, notarized, and independently audited.

## Reporting

Do not include captured screens, accessibility dumps, API keys, or personal data in public bug reports. Reproduce grounding bugs with the smallest safe fixture or a synthetic application.
