# Beacon architecture

Beacon keeps perception, reasoning, grounding, and rendering separate so every decision can be inspected.

```text
explicit user request
  → local semantic + structural request-mode classification
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

`VisionSceneAnalyzer` runs Apple's Vision framework locally. It combines OCR with rectangle detection and light/dark contour analysis, classifying normalized candidates as text, rectangle, circle, icon, or freeform canvas shape. Nearby OCR labels are associated with detected shapes when possible. Sensitive candidates are removed before model context is created, and the image is redacted before it becomes eligible for a privacy preview or provider request.

## Grounding

Models select stable element IDs whenever possible. `AccessibilityGrounder` resolves those IDs to locally known bounds. `VisualGrounder` accepts only validated normalized bounding boxes. `SetOfMarksBuilder` deterministically combines accessible controls with uncovered local-vision candidates, and models can return a mark number that must exist in that exact table. `HybridGrounder` preserves the Accessibility-first priority and resolves validated marks or visual bounds without coupling the overlay to a provider.

The local matcher automatically ranks mark labels, shape types, and spatial phrases such as “circle on the right.” When separately consented OpenAI visual reasoning is enabled, Beacon draws the same marks over the locally redacted image before sending it. The exact outbound image remains visible under Privacy.

The overlay accepts only `GroundedTarget`, so it cannot tell whether a target came from AX, local vision, Set-of-Marks, or a cloud model.

## Instructor lifecycle

The UI has one **Ask Beacon** entry point. `RequestModeClassifier` combines an on-device Natural Language sentence embedding with structural action/explanation evidence and matches against the currently visible scene. It returns a scored classification while keeping the simpler one-shot answer path and verified multi-step task path internal.

`InstructorStateMachine` makes each guide step explicit:

```text
idle → capturingScene → understanding → grounding → presenting
     → waitingForChange → verifying → completed
```

Cancellation returns any state to idle. Invalid transitions throw. While a visible guide step is active, `AccessibilityChangeObserver` listens for focus, value, menu, window, layout, move, and resize notifications. A three-second fallback timer covers applications that do not publish useful events. Visual verification samples remain local and in memory. Successful verification advances the same guide with completed-step context, up to an eight-step safety limit.

`ApplicationGuidePolicyRegistry` contains guidance-only fixtures for common TextEdit, Preview, Finder, Safari, and System Settings tasks. It can recover from layout differences, retries unexpected or missing changes within application-specific limits, and stops with an actionable message when an outcome cannot be confirmed. It never performs the action for the user.

## Providers

`InstructorModel` exposes capabilities and one typed async method. Current adapters are:

- `AccessibilityHeuristicProvider`: deterministic, local, and the default;
- `AppleFoundationModelProvider`: local language reasoning on supported systems;
- `OpenAIProvider`: optional structured output over the Responses API, with separately consented redacted image input.

`ModelContextBuilder` ranks focused, semantically relevant, actionable controls and enforces strict element and character budgets. This prevents large browser or IDE accessibility trees from overflowing local context windows. Apple output uses a native `@Generable` schema and retries once with a smaller context budget. All model actions are validated against the current scene before rendering. Unknown IDs and out-of-range rectangles are rejected.

## Next milestones

1. Expand application fixtures from real-world, privacy-safe failure reports.
2. Add domain-specific CAD semantics without reading or modifying document data.
3. Signed release packaging and a documented threat model review.
