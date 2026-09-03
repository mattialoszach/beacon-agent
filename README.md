# Beacon

**Ask. See. Do.**

Beacon is an open-source, privacy-first macOS instructor. Press **Option + Space**, ask how to do something in the app in front of you, and Beacon highlights the real accessible control without taking over your mouse.

This repository contains the native v0.1 grounding prototype and verified multi-step guide loop described in the product brief.

## What works

- Native SwiftUI/AppKit app with both a menu bar and normal window
- Global Option + Space prompt positioned beside the pointer
- A compact morphing glass bubble while Beacon captures, reasons, grounds, and verifies
- One Ask Beacon entry point with local semantic, structural, and visible-scene intent classification
- Focused-app Accessibility tree extraction with stable per-scene element IDs
- One normalized, top-left coordinate space across Retina and multiple displays
- Click-through rectangle, circle, and spotlight overlays, with arrows that stop outside the target edge
- Solid-color guidance arrows and a live proximity fade that reveals the interface beneath nearby Beacon guidance
- Focus-safe teacher status HUD that explains when Beacon is checking or waiting for the user
- Stale-scene protection that tolerates transient UI updates, pauses vanished targets, and resumes after menus or windows are restored
- Overlay target tracking while windows move
- Local deterministic semantic element matching
- Local Vision OCR plus rectangle, circle, icon, and freeform-shape detection
- Automatic numbered Set-of-Marks generation, model selection, validation, and candidate mapping
- Typed provider boundary, Apple Foundation Models adapter, and optional OpenAI adapter
- Bounded model contexts with native structured Apple Foundation Models output
- Verified multi-step guides with an eight-step safety limit
- Expected-outcome verification across intermediate Accessibility events, with a bounded low-rate fallback
- Tested recovery recipes for TextEdit, Preview, Finder, Safari, and System Settings
- ScreenCaptureKit privacy preview with local password, email, phone, card, and API-key redaction
- Per-application capture exclusions plus separate cloud-text and redacted-image opt-ins
- Optional Developer Inspector and live “draw all elements” overlay, hidden by default

Beacon never clicks UI controls in v0.1.

## Requirements

- macOS 14 or newer
- Xcode command line tools with Swift 5.10 or newer
- Accessibility permission for UI grounding
- Screen Recording permission for screenshots and the privacy preview (optional for accessibility-only grounding)

Apple Foundation Models are compiled and offered on macOS 26+. The deterministic accessibility and local-vision matcher remains the default and requires no model download or API key. Optional OpenAI visual reasoning requires both cloud processing and the separate redacted-preview consent toggle; the exact numbered image is shown under **Privacy**.

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
