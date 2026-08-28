# Privacy model

Beacon's default path is local and accessibility-only. No account, API key, screenshot, or external model is required.

## Capture rules

- Capture starts only after Option + Space, a visible menu action, or an explicit Developer Inspector refresh.
- Screen Recording is optional for the default grounder.
- Applications in the exclusion list never produce screenshots and are forced onto the local deterministic provider.
- Password values are removed during Accessibility extraction.
- Secure text-field rectangles are masked locally before a screenshot is stored as the current privacy preview.
- Overlay and prompt windows are rendered locally and never become model drawing input.

## Cloud boundary

Cloud processing has a separate opt-in and is disabled by default. The current OpenAI adapter sends the user's question plus structured application, window, and accessible-control metadata. It does **not** attach the screenshot. API keys are kept in the macOS Keychain, not UserDefaults or repository files.

The Developer Inspector's **What the model sees** panel displays the exact redacted screenshot object available to providers and reports the number of hidden regions. Because the current cloud adapter is text-only, that image does not leave the machine.

## Known limits

- Automatic image redaction currently covers AX secure text fields. OCR detection for emails, phone numbers, cards, and API keys is not implemented.
- Accessibility labels can themselves contain sensitive text. Exclude sensitive apps and keep cloud processing disabled when this matters.
- ScreenCaptureKit permission is controlled by macOS and associated with the packaged app identity.
- Ad-hoc development builds are not a production trust boundary. Release builds should be hardened, signed, notarized, and independently audited.

## Reporting

Do not include captured screens, accessibility dumps, API keys, or personal data in public bug reports. Reproduce grounding bugs with the smallest safe fixture or a synthetic application.
