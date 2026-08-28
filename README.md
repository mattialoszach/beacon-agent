# Beacon

**Ask. See. Do.**

Beacon is an open-source, privacy-first macOS instructor. Press **Option + Space**, ask how to do something in the app in front of you, and Beacon highlights the real accessible control without taking over your mouse.

This repository contains the native v0.1 grounding prototype and single-step guide loop described in the product brief.

## What works

- Native SwiftUI/AppKit app with both a menu bar and normal window
- Global Option + Space prompt positioned beside the pointer
- Focused-app Accessibility tree extraction with stable per-scene element IDs
- One normalized, top-left coordinate space across Retina and multiple displays
- Click-through rectangle, arrow, circle, and spotlight overlays
- Overlay target tracking while windows move
- Local deterministic semantic element matching
- Typed provider boundary, Apple Foundation Models adapter, and optional OpenAI adapter
- Event-driven step verification from Accessibility changes
- ScreenCaptureKit privacy preview with local password-field redaction
- Per-application capture exclusions and cloud-processing opt-in
- Developer inspector and live “draw all elements” overlay

Beacon never clicks UI controls in v0.1.

## Requirements

- macOS 14 or newer
- Xcode command line tools with Swift 5.10 or newer
- Accessibility permission for UI grounding
- Screen Recording permission for screenshots and the privacy preview (optional for accessibility-only grounding)

Apple Foundation Models are compiled and offered on macOS 26+. The deterministic accessibility matcher remains the default and requires no model download or API key.

## Build and run

```sh
chmod +x scripts/build-app.sh
./scripts/build-app.sh
open .build/Beacon.app
```

On first launch, open **Permissions** and grant Accessibility. Grant Screen Recording only if you want screenshot context and the “What the model sees” preview.

For command-line development:

```sh
swift build
swift test
```

Running the packaged app is recommended because macOS attaches privacy permissions to the app bundle identity.

## First grounding check

1. Open a standard macOS application such as TextEdit or Preview.
2. Press Option + Space and ask “Where is Print?” or “How do I export this?”
3. Beacon selects an accessible candidate and renders a native click-through overlay.
4. Open **Developer Inspector** to inspect exact IDs, bounds, the selected strategy, and the redacted image.
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

The v0.1 loop intentionally prioritizes accessibility grounding. Visual-region targets and hybrid strategy interfaces are present, but screenshot-based candidate detection, Set-of-Marks image annotation, OCR redaction, multi-step task planning, and autonomous actions are future milestones.

## License

A project license has not yet been selected. Add an OSI-approved license before distributing binaries or accepting contributions.
