<p align="center">
  <img src="Beacon/Resources/Images/AppIcon.png" alt="Beacon app icon" width="150">
</p>

# Beacon

**Ask. See. Do.**

Beacon is a privacy-first, native macOS instructor that shows you where to go next without taking control of your computer. Press **Option + Space**, describe what you want to do in the app in front of you, and Beacon highlights the relevant control with a clear, click-through overlay.

> [!NOTE]
> Beacon is under active development. Features, behavior, and setup requirements may change.

## Highlights

- Native SwiftUI and AppKit interface with menu bar and standard window entry points
- Global **Option + Space** shortcut with a compact request panel beside the pointer
- Accessibility-based control discovery with stable element identifiers
- Local Vision text recognition and visible control-shape detection
- Accurate placement across Retina, mixed-scale, and multi-display setups
- Click-through spotlight, outline, arrow, and instruction overlays
- Guided multi-step workflows that check for the expected interface change before continuing
- Fast cancellation with **Escape**, **Pause Screen Access**, or **Dismiss Overlay**
- ScreenCaptureKit privacy preview with local redaction for passwords and sensitive text
- Per-application capture exclusions and explicit consent controls
- Optional Developer Inspector and live geometry overlay for troubleshooting

Beacon does not click, type, drag, or otherwise operate interface controls for you.

## Requirements

- macOS 14 or newer
- Xcode command line tools with Swift 5.10 or newer
- Accessibility permission for interface guidance
- Screen Recording permission for local screenshot context, text recognition, shape detection, and the privacy preview

Screen Recording is optional when Accessibility information alone is sufficient.

## Build and run

```sh
chmod +x scripts/build-app.sh
./scripts/build-app.sh
open .build/Beacon.app
```

On first launch, open **Permissions** in Beacon and grant Accessibility access. Grant Screen Recording only if you want the additional local visual features.

For command-line development:

```sh
swift build
swift test
```

Running the packaged app is recommended because macOS associates privacy permissions with the app bundle identity.

The build script uses ad-hoc signing for local testing by default. Because an ad-hoc signature changes with each build, macOS may require Accessibility and Screen Recording permissions to be enabled again after rebuilding. Set `BEACON_SIGNING_IDENTITY` to a stable signing identity to preserve those grants. Set `BEACON_BUILD_UNIVERSAL=1` to include Apple Silicon and Intel binaries.

For distribution and notarization instructions, see [Development](Docs/DEVELOPMENT.md#release-checklist) and the [release review and manual test plan](Docs/RELEASE_REVIEW.md).

## Try it

1. Open a standard macOS application such as TextEdit or Preview.
2. Press **Option + Space**.
3. Enter a request such as “Where is Print?” or “How do I export this?”
4. Follow the highlighted controls while completing each action yourself.
5. Press **Escape** at any time to stop guidance and remove the overlay.

Requests can continue across windows and applications. Beacon removes stale highlights, reassesses the visible interface, and waits for controls that appear after opening a menu, sheet, or settings page. Guides stop after eight steps, and capture exclusions continue to apply when the active application changes.

## Privacy and control

Beacon captures the screen only after an explicit request or while checking the result of a visible guide step. Observation frames remain in memory and are not written to disk. Password fields and locally detected sensitive text are removed from retained previews, and configured applications can be excluded from capture entirely.

The **Privacy** screen shows capture controls and any preview eligible to leave the Mac. See [Privacy](Docs/PRIVACY.md) for the complete data-handling rules.

## Project structure

```text
Beacon/
├── App/                 SwiftUI app, menu bar, request panel, and main window
├── Core/                scenes, target selection, geometry, and guide state
├── Platform/macOS/      Accessibility, ScreenCaptureKit, permissions, and hotkey
├── Overlay/             native click-through guidance rendering
├── Privacy/             exclusions, redaction, and privacy preview data
├── Providers/           local and optional service adapters
└── DeveloperTools/      perception and target-selection inspector
```

See [Architecture](Docs/ARCHITECTURE.md), [Privacy](Docs/PRIVACY.md), and [Development](Docs/DEVELOPMENT.md) for implementation details.

## Current boundaries

Beacon prioritizes Accessibility identifiers, then locally recognized text and visible control shapes, followed by validated numbered regions. Geometry is always checked against the current display layout before a guide is shown.

Voice input and autonomous clicking, typing, or dragging are outside the current scope. Beacon explains and points while you remain in control.

## License

Beacon is available under the [MIT License](LICENSE).
