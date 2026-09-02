# Development

## Commands

```sh
swift build
swift test
./scripts/build-app.sh
open .build/Beacon.app
```

The package targets macOS 14. Apple Foundation Models code is availability-gated for macOS 26.

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

The current suite covers canonical coordinates, context budgeting, rectangle validation, Accessibility/local-vision/Set-of-Marks selection, request-mode classification, application recipes, target validation, instructor transitions, recovery limits, outcome verification, sensitive-text classification, provider image consent, and display-scoped redaction. Add regression tests before changing coordinate conversion or model schemas.

## Release checklist

- Select an OSI-approved license.
- Replace ad-hoc signing with a Developer ID identity and enable hardened runtime.
- Notarize the app and verify permission persistence across updates.
- Publish a full threat model and provider data-retention notes.
- Test mixed-scale displays positioned above, below, and left of the main display.
