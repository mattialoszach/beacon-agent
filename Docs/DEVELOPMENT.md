# Development

## Commands

```sh
swift build
swift test
./scripts/build-app.sh
open .build/Beacon.app
```

The package targets macOS 14. Apple Foundation Models code is availability-gated for macOS 26.

## Debugging grounding

Use Developer Inspector to capture the active app, examine its normalized AX descriptors, and render every detected element. Move the inspected window between displays while the debug overlay is visible; labels and rectangles refresh twice per second.

When adding a grounding strategy:

1. accept a `UIIntention` and immutable `ScreenScene`;
2. return a validated `GroundingResult`;
3. preserve top-left normalized geometry;
4. never expose provider objects to the overlay;
5. add deterministic unit fixtures.

## Test focus

The current suite covers canonical coordinates, rectangle validation, semantic selection, target validation, instructor transitions, and display-scoped redaction. Add regression tests before changing coordinate conversion or model schemas.

## Release checklist

- Select an OSI-approved license.
- Replace ad-hoc signing with a Developer ID identity and enable hardened runtime.
- Notarize the app and verify permission persistence across updates.
- Publish a full threat model and provider data-retention notes.
- Test mixed-scale displays positioned above, below, and left of the main display.
