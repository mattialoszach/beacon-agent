# Development

## Commands

```sh
swift build
swift test
./scripts/build-app.sh
open .build/Beacon.app
```

The package targets macOS 14. Apple Foundation Models code is availability-gated for macOS 26 and the framework is weakly linked, so the binary loads on macOS 14 and 15.

The default build is ad-hoc signed. Its designated requirement is the code hash alone, which changes on every build, so macOS treats each rebuilt app as a different principal: Accessibility and Screen Recording must be re-enabled and the login Keychain prompts again for the stored API key. To keep those grants across builds, create a self-signed code-signing certificate in Keychain Access and export its name:

```sh
export BEACON_SIGNING_IDENTITY='Beacon Local Development'
./scripts/build-app.sh
```

## Previewing the thinking animation

Launch an isolated prompt preview without Screen Recording or Accessibility access:

```sh
./scripts/build-app.sh
open -n .build/Beacon.app --args --preview-thinking
```

Type any text and press Return to run the real prompt-to-teacher-status transition. The status HUD shows Beacon’s current processing message without becoming key or intercepting clicks. Press Escape to dismiss it. This preview path does not capture a scene or invoke a model.

## Debugging grounding

Developer Inspector is hidden from the sidebar by default. Enable **Show Developer Inspector** under **Models** to capture the active app, examine normalized Accessibility, OCR, rectangle, circle, icon, and freeform candidates, inspect intent confidence, and render detected accessible elements. Move the inspected window between displays while the debug overlay is visible; labels and rectangles refresh twice per second.

When adding a grounding strategy:

1. accept a `UIIntention` and immutable `ScreenScene`;
2. return a validated `GroundingResult`;
3. preserve top-left normalized geometry;
4. never expose provider objects to the overlay;
5. add deterministic unit fixtures.

## Test focus

The current suite covers canonical coordinates (including displays above and left of the main screen, clipping, and rejection of invalid rectangles), context budgeting, rectangle validation and display containment, Accessibility/local-vision/Set-of-Marks selection and badge placement, grounding priority order, request-mode classification, application recipes, target validation, the complete instructor transition table, recovery limits, outcome verification, secure-field and sensitive-text redaction, cloud response validation and refusal handling, capture exclusion, display-change handling, and frame-difference boundaries. Add regression tests before changing coordinate conversion or model schemas.

Tests must stay deterministic and offline: use the injected `captureScene`, `captureSnapshot`, `observationEvents`, `currentDisplays`, and `apiKeyStorage` seams rather than real capture, Accessibility, Keychain, or network access.

## Release checklist

Read [the release review and manual test plan](RELEASE_REVIEW.md) before declaring a build ready. The code fixes have deterministic coverage; release signing and real-app acceptance still need the owner's environment.

For a universal local test build:

```sh
BEACON_BUILD_UNIVERSAL=1 ./scripts/build-app.sh
codesign --verify --deep --strict .build/Beacon.app
```

Install your Developer ID Application certificate and its private key, then select the identity reported by `security find-identity -v -p codesigning`:

```sh
export BEACON_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)'
./scripts/release-app.sh check
./scripts/release-app.sh prepare
open .build/Beacon.app
```

`prepare` enables hardened runtime, a secure timestamp, and both CPU architectures. Test this signed app before notarizing it. Notarization requires credentials stored in Keychain. Use the interactive credential setup so secrets do not enter shell history:

```sh
xcrun notarytool store-credentials BeaconNotary
export BEACON_NOTARY_PROFILE=BeaconNotary
./scripts/release-app.sh notarize "$PWD/.build/Beacon.app"
```

The `notarize` command uploads a copy of the exact supplied app to Apple, requires an **Accepted** result, staples and validates the ticket, checks Gatekeeper, and creates `Beacon.zip` with a SHA-256 checksum in a new `.build/releases/Beacon.*` directory. It never rebuilds, commits, or publishes the app. A rejected submission produces no final distribution ZIP. If Apple's processing times out, retain `notarization.plist` and use the submission ID with `xcrun notarytool info`, `wait`, or `log` to diagnose it. Avoid repeatedly resubmitting a pending build.

This follows Apple's [distribution signing](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac) and [custom notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

Before public distribution:

- Select the project license.
- Run acceptance tests with the signed app, including first launch, permission denial/regrant, and permission persistence across an update.
- Validate the final downloaded/quarantined artifact on a clean Mac.
- Test mixed-scale displays, display disconnection, Preview PDF export from JPEG/PNG, and cancelled export dialogs.
- Test the oldest supported macOS and Intel runtime, and a real OpenAI account with each consent mode.
- Finish the threat model and provider data-retention review.
