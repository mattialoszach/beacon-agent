# Beacon architecture

Beacon keeps perception, reasoning, grounding, and rendering separate so every decision can be inspected.

```text
explicit user request
  → AccessibilityService + ScreenCaptureService
  → ScreenScene (normalized geometry)
  → local privacy policy + RedactionService
  → InstructorModel (typed request/response)
  → response validation
  → HybridGrounder
  → GroundedTarget
  → native OverlayController
  → local change observation and verification
```

## Canonical geometry

`CoordinateSpaceMapper` is the only conversion boundary. Beacon represents the complete virtual desktop with a top-left origin and normalized coordinates in `0 ... 1`.

It converts:

- global Accessibility/Quartz points to normalized Beacon rectangles;
- normalized rectangles back to global AppKit rectangles, including one deliberate Y-axis inversion;
- capture pixels into the normalized bounds of their source display.

Overlay windows are one transparent, click-through `NSPanel` per `NSScreen`. Each view converts the global AppKit target to screen-local SwiftUI geometry. Unit tests cover negative display origins, round trips, screenshot mapping, and Y inversion.

## Scene capture

`AccessibilityService` visits the focused application's hierarchy with depth and element-count limits, loop detection, bounds validation, and secure-field value suppression. It emits `UIElementDescriptor` values; platform objects never cross into the reasoning layer.

`ScreenCaptureService` uses ScreenCaptureKit and captures a single relevant display only after explicit interaction. Screenshots are optional. Accessibility-only guidance remains available when Screen Recording is denied.

## Grounding

Models select stable element IDs whenever possible. `AccessibilityGrounder` resolves those IDs to locally known bounds. `VisualGrounder` accepts only validated normalized bounding boxes. `HybridGrounder` prefers Accessibility and preserves the visual fallback boundary without coupling either path to a provider.

The overlay accepts only `GroundedTarget`, so it cannot tell whether a target came from AX, local vision, Set-of-Marks, or a cloud model.

## Instructor lifecycle

`InstructorStateMachine` makes the single-step lifecycle explicit:

```text
idle → capturingScene → understanding → grounding → presenting
     → waitingForChange → verifying → completed
```

Cancellation returns any state to idle. Invalid transitions throw. Observation polls lightweight Accessibility fingerprints only while a guide expects change; it does not continuously upload or capture frames.

## Providers

`InstructorModel` exposes capabilities and one typed async method. Current adapters are:

- `AccessibilityHeuristicProvider`: deterministic, local, and the default;
- `AppleFoundationModelProvider`: local language reasoning on supported systems;
- `OpenAIProvider`: optional structured output over the Responses API.

All model actions are decoded into `InstructorResponse` and validated against the current scene before rendering. Unknown IDs and out-of-range rectangles are rejected.

## Next milestones

1. Annotated Set-of-Marks capture and mapping table.
2. Vision candidate detection and OCR redaction.
3. AXObserver-driven change events plus local perceptual frame differencing.
4. Multi-step plan memory and expected-outcome-specific verification.
5. Signed release packaging and a documented threat model review.
