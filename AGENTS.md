# AGENTS.md

This file defines repository-wide instructions for contributors and coding agents working on Beacon.

## Product intent

Beacon is a native, privacy-first macOS AI instructor. It observes the current interface, explains the next step, and renders visual guidance while the user remains in control.

Beacon is not an autonomous computer-use agent. Do not add automatic clicking, typing, dragging, or destructive UI actions unless the project scope is explicitly changed.

## Supported platform and stack

- Target macOS 14 or newer.
- Use Swift, SwiftUI, and AppKit.
- Use ScreenCaptureKit for screen capture.
- Use macOS Accessibility APIs for primary UI grounding.
- Use Vision for local OCR and visual analysis.
- Use Apple Foundation Models when available and keep providers replaceable.
- Do not introduce Electron or a cross-platform UI framework.

## Commands

Run these from the repository root:

```sh
swift build
swift test
./scripts/build-app.sh
open .build/Beacon.app
```

The optional on-device model integration test is gated because it invokes the real Apple Foundation Model:

```sh
BEACON_RUN_MODEL_TESTS=1 swift test \
  --filter AppleFoundationModelIntegrationTests/testLargeSceneDoesNotOverflowLocalModelContext
```

Before handing off code changes, run `swift test` and `git diff --check`. For changes involving packaging, permissions, entitlements, or app startup, also run `./scripts/build-app.sh` and verify the resulting app with `codesign --verify --deep --strict .build/Beacon.app`.

## Architecture boundaries

Keep the data flow explicit and auditable:

```text
explicit user request
  → platform capture
  → ScreenScene
  → local privacy filtering
  → bounded InstructorRequest
  → InstructorModel
  → validated InstructorResponse
  → GroundedTarget
  → native overlay
  → local change verification
```

Follow these boundaries:

- Platform APIs belong under `Beacon/Platform/macOS`.
- Provider-independent scene, model, grounding, and state types belong under `Beacon/Core`.
- Model providers belong under `Beacon/Providers`.
- Providers must not render overlays or access AppKit windows directly.
- Overlay code must accept `GroundedTarget`; it must not depend on a specific model provider.
- Privacy filtering must happen before data becomes eligible for an external provider.
- Keep dependencies injectable or protocol-driven where that improves testability.
- Avoid large singleton objects and implicit global state.

See `Docs/ARCHITECTURE.md` and `Docs/PRIVACY.md` before changing capture, grounding, model routing, or redaction behavior.

## Coordinate-system rules

Beacon uses one canonical coordinate system:

- top-left origin;
- normalized values in `0 ... 1`;
- coordinates span the complete virtual desktop.

All conversions must go through `CoordinateSpaceMapper`. Do not scatter Y-axis inversion, Retina scaling, display translation, or screenshot-to-screen conversion throughout the codebase.

Every coordinate change needs tests covering relevant combinations of:

- negative display origins;
- multiple displays;
- differing scale factors;
- AppKit/Quartz Y-axis conversion;
- screenshot-pixel conversion;
- invalid and overflowing rectangles.

## Grounding rules

Use this priority order:

1. Accessibility element ID and locally known bounds.
2. Accessibility plus local visual context.
3. Validated visual bounding box.
4. Set-of-Marks or other visual fallback.

Models should select stable element IDs instead of inventing pixel coordinates. Never apply a model-generated target without validating that:

- its element ID exists in the current scene; or
- its normalized rectangle is finite and fully inside the screen.

Accessibility trees can be very large. All provider prompts must use `ModelContextBuilder` or an equivalent deterministic budget. Do not send an unbounded scene to a model.

## Privacy and capture invariants

These are release-blocking requirements:

- Never implement hidden continuous recording.
- Capture only after explicit user interaction or while verifying a visible guide step.
- Do not write screenshots or observation frames to disk.
- Exclude Beacon and configured excluded applications through ScreenCaptureKit.
- Keep screenshots local unless a future feature obtains explicit user consent and exposes the exact outbound image.
- The current OpenAI provider is text-only; do not attach screenshots silently.
- Remove password values during Accessibility extraction.
- Redact secure fields and locally detected sensitive text before retaining a privacy-preview image.
- Excluded applications must use a local provider and must not produce screenshots.
- Store API keys in macOS Keychain, never UserDefaults, source files, logs, or fixtures.
- Show the exact bounded outbound text in Developer Inspector.

Temporary frame samples used for local change detection must remain in memory and must not be sent to any model.

## Model-provider rules

All providers conform to `InstructorModel` and return typed `InstructorResponse` values.

- Prefer structured generation over prose parsing.
- Validate every response before grounding or presentation.
- Preserve completed-step context for multi-step guides.
- Keep provider-specific request and response details inside the provider directory.
- Do not hard-code secrets or assume cloud availability.
- A local fallback must remain available when Apple Intelligence or cloud processing is unavailable.
- Respect application exclusions and the `Local Only` processing mode.

Apple Foundation Models prompts must remain bounded and use native generated schemas. Keep the reduced-context retry for context-window failures.

## Instructor workflow

Guide mode is a state machine, not a one-shot chat response:

```text
idle
  → capturingScene
  → understanding
  → grounding
  → presenting
  → waitingForChange
  → verifying
  → next step or completed
```

- Keep transitions explicit and tested.
- Escape must cancel promptly and remove overlays.
- Overlays must remain click-through.
- Verify the expected outcome rather than assuming that a user action succeeded.
- Stop multi-step guides at the configured safety limit.
- Do not invoke expensive model reasoning continuously while waiting.

## Testing requirements

Add or update deterministic tests for changes involving:

- coordinate mapping and normalized geometry;
- model-context ranking and budgets;
- model response decoding and validation;
- semantic or visual target selection;
- state-machine transitions;
- expected-outcome verification;
- redaction and sensitive-text classification;
- frame-difference detection;
- Set-of-Marks rendering and mapping.

Avoid making the normal test suite depend on network access, screen-recording permission, Accessibility permission, or Apple Intelligence availability. Gate real-model or permission-dependent integration tests behind explicit environment variables.

## UI expectations

- Keep the app native and keyboard accessible.
- Menu bar interaction is the lightweight primary entry point.
- Maintain a normal application window for history, privacy, models, permissions, and developer tools.
- Overlays must not intercept normal mouse input.
- Errors should be actionable and dismissible.
- Developer Inspector should make perception and grounding failures easy to diagnose.

## Documentation and scope

Update `README.md` and relevant files under `Docs/` when behavior, privacy boundaries, permissions, provider data flow, or supported features change.

Current non-goals include autonomous clicking, voice input, cross-platform support, plugin marketplaces, and workflow automation. Advanced CAD viewport understanding and non-text control-shape recognition are not yet implemented; do not describe them as working features.
