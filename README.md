# Beacon

**Ask. See. Do.**

Beacon is a privacy-first macOS instructor. Press **Option + Space**, ask how to do something in the app in front of you, and Beacon highlights the real accessible control without taking over your mouse.

This repository contains the native v0.1 grounding prototype and verified multi-step guide loop described in the product brief.

## What works

- Native SwiftUI/AppKit app with both a menu bar and normal window
- Global Option + Space prompt positioned beside the pointer
- A compact morphing glass bubble while Beacon captures, reasons, grounds, and verifies
- One Ask Beacon entry point with local semantic, structural, and visible-scene intent classification
- Focused-app Accessibility tree extraction with stable per-scene element IDs
- One normalized, top-left coordinate space across Retina and multiple displays
- Consistent click-through spotlight guidance with rectangle or circle target outlines, plus arrows that stay clear of the instruction callout and stop outside the target edge
- Purple on-screen instructions and arrows for every grounded step, on a system-adaptive material that follows Light or Dark appearance; they start fully visible, then fade near the pointer after it moves
- Focus-safe teacher status HUD that explains when Beacon is checking or waiting for the user
- Stale-scene protection that follows app/window changes with fresh guidance and waits for vanished controls or closed menus to return
- Overlay target tracking while windows move
- Local deterministic semantic element matching
- Local Vision OCR plus rectangle, circle, icon, and freeform-shape detection
- Automatic numbered Set-of-Marks generation, model selection, validation, and candidate mapping
- Typed provider boundary, Apple Foundation Models adapter, and optional OpenAI adapter
- Bounded model contexts with native structured Apple Foundation Models output
- Verified multi-step guides with an eight-step safety limit
- Continuous navigation guidance for menus, settings, and account/profile flows: a newly opened screen is replanned into the next arrow instead of being mistaken for completion
- Specific control/value/window outcome checks, with explicit confirmation when success cannot be established locally
- Window identity and display-change invalidation to prevent stale guidance
- Fixture-tested recipes for TextEdit, Preview, Finder, Safari, and System Settings, including Appearance → Dark; real-app acceptance testing remains required
- ScreenCaptureKit privacy preview with local password, email, phone, card, and API-key redaction
- Per-application capture exclusions plus separate cloud-text and redacted-image opt-ins
- Optional Developer Inspector and live “draw all elements” overlay, hidden by default

Beacon never clicks UI controls in v0.1.

## Requirements

- macOS 14 or newer
- Xcode command line tools with Swift 5.10 or newer
- Accessibility permission for UI grounding
- Screen Recording permission for screenshots and the privacy preview (optional for accessibility-only grounding)

Apple Foundation Models are compiled on every supported system and used only on macOS 26 or newer with Apple Intelligence available. When no provider preference has been saved, Beacon prefers this on-device reasoning path; an older or unsupported system automatically falls back to the deterministic Accessibility and local-vision matcher. An explicitly selected provider is preserved. Neither local path requires an API key or sends screen content off the Mac. Optional OpenAI visual reasoning requires both cloud processing and the separate redacted-preview consent toggle; the exact numbered image is shown under **Privacy**.

## Build and run

```sh
chmod +x scripts/build-app.sh
./scripts/build-app.sh
open .build/Beacon.app
```

On first launch, open **Permissions** and grant Accessibility. Grant Screen Recording only if you want local screenshot context, OCR and control-shape grounding, and the redacted preview.

For command-line development:

```sh
swift build
swift test
```

Running the packaged app is recommended because macOS attaches privacy permissions to the app bundle identity.

The build script uses ad-hoc signing by default for local testing. An ad-hoc signature is identified only by its code hash, which changes on every build, so macOS treats each rebuild as a different application: re-enable Beacon under **Privacy & Security → Accessibility** and **Screen Recording** after rebuilding, and expect a Keychain prompt the first time a stored API key is read. Set `BEACON_SIGNING_IDENTITY` to a stable signing identity to keep those grants across builds. Set `BEACON_BUILD_UNIVERSAL=1` to include Apple Silicon and Intel binaries. For distribution, set `BEACON_SIGNING_IDENTITY` to your Developer ID Application identity; this enables hardened runtime and a secure timestamp. Use `scripts/release-app.sh prepare` for a signed universal candidate, test it, then explicitly notarize that exact bundle using `scripts/release-app.sh notarize /path/to/Beacon.app`. See [release setup](Docs/DEVELOPMENT.md#release-checklist). See the [release review and manual test plan](Docs/RELEASE_REVIEW.md) before distributing a build.

Pause Screen Access, Escape, and Dismiss Overlay stop active guidance. Escape is handled by whichever Beacon window is in front, so it still closes an ordinary dialog without cancelling a guide. Changes to cloud consent or application exclusions cancel the current request and discard pending results; start a new request after changing privacy settings. If a configured reasoning provider fails, Beacon reports the failure beside the pointer and falls back to local matching, whether or not the main window is open. A missing matching control does not establish that the task is complete. Ambiguous results appear under **Check the result** in Home and in the menu: choose **Confirm Result** only after checking the result, or **That Didn’t Work** to stop. Cancelling an export dialog never confirms a saved file. A real display layout change stops guidance and requires a new request; the Dock or menu bar changing size does not.

Requests can span applications: for example, start in Safari and use Apple → About This Mac to find memory information. When the active app, window, menu, or account panel changes, Beacon removes the old highlight and reassesses the new screen with the same question and completed-step history. This lets a request such as changing a Google profile picture continue from the avatar to the account menu, and a VS Code theme request continue from **Code** to the next menu command even when Electron exposes the same Accessibility tree before and after opening the menu. Beacon uses the targeted macOS menu-open notification, selected menu state, or a permitted local frame comparison; opening an unrelated menu and focus changes alone do not confirm a step. Navigation observation is bounded, and repeated capture failures stop with an actionable error instead of leaving the guide stuck. Each request allows up to eight reassessments, and the destination app's privacy exclusions still apply. New instructions, answers, and thinking messages appear at full opacity even if the pointer is already over them; moving it enables the proximity fade.

## First grounding check

1. Open a standard macOS application such as TextEdit or Preview.
2. Press Option + Space and ask “Where is Print?” or “How do I export this?”
3. Beacon infers the request type, selects an accessible candidate, and renders a native click-through overlay when guidance is needed.
4. Under **Models**, enable **Show Developer Inspector**, then open it to inspect exact IDs, bounds, the selected strategy, and the redacted image.
5. Choose **Draw All Elements** to validate geometry live while moving the target window.

## Project map

```text
Beacon/
├── App/                 SwiftUI app, menu bar, prompt, and main window
├── Core/                scenes, grounding, model schemas, state machine
├── Platform/macOS/      AX, ScreenCaptureKit, coordinates, permissions, hotkey
├── Overlay/             native click-through overlay rendering
├── Privacy/             exclusions, redaction, privacy preview data
├── Providers/           local, Apple, and optional cloud adapters
└── DeveloperTools/      perception and grounding inspector
```

See [Architecture](Docs/ARCHITECTURE.md), [Privacy](Docs/PRIVACY.md), and [Development](Docs/DEVELOPMENT.md).

## Current boundary

The v0.1 loop prioritizes Accessibility IDs, then local OCR and control-shape candidates, then validated Set-of-Marks regions. With explicit visual-preview consent, OpenAI can select numbered targets from the locally redacted image. Domain-specific CAD object semantics can still vary by application; Beacon grounds visible geometry but does not inspect a document's internal CAD model.

Voice and autonomous clicking, typing, or dragging remain non-goals. Beacon explains and points while the user stays in control.

## License

A project license has not yet been selected. Add an OSI-approved license before distributing binaries or accepting contributions.
