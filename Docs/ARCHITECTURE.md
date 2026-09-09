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

Overlay windows are one transparent, click-through `NSPanel` per `NSScreen`. Each view converts the global AppKit target to screen-local SwiftUI geometry. Every grounded step dims the target's display, cuts out the target at normal brightness, and renders a Beacon-purple instruction and arrow in addition to its requested outline shape. The spotlight layer remains stable for the complete step; pointer-proximity fading applies only to the outline, arrow, and callout, so moving toward the target cannot make the dimming treatment disappear. The instruction uses a system-adaptive material rather than a fixed light fill, and model-authored Markdown emphasis is converted to native attributed text in user-facing response surfaces. Arrow layout starts on the side opposite the callout, moves to another free side if needed, keeps the complete visible arrow clear of the measured callout, and always terminates outside the target edge. Guidance decorations and non-interactive status HUDs start fully visible and enable proximity fading only after a pointer movement following that presentation. Each new instruction or status message records its own movement baseline; target tracking preserves that baseline. The interactive question field does not fade. Unit tests cover initial overlap and subsequent movement, callout avoidance, negative display origins, cursor mapping, round trips, screenshot mapping, and Y inversion.

## Scene capture

`AccessibilityService` visits the focused application's hierarchy on a background executor with depth, elapsed-time, visited-node, and output limits. A process-wide Accessibility messaging timeout bounds every cross-process read, including the ones the change observer makes on the main run loop, so an unresponsive target application cannot stall Escape or overlay updates. A capture that hits any budget is marked truncated. Whole-interface and visual freshness comparisons treat it as explicitly inconclusive, but a surviving Accessibility target can still be presented when its app, window, display, stable element identity, enabled state, and fresh bounds all validate. A missing or changed target still fails closed. Attribute reads are batched to reduce cross-process calls, while loop detection, bounds validation, and secure-field value suppression remain enforced. It emits `UIElementDescriptor` values; platform objects never cross into the reasoning layer. A bounded, process-local registry compares AX window objects to preserve window identity across captures. Controls carry their owning window ID; capture retains the focused window, its sheets, and application menus. Window titles alone never establish identity. Rectangles are clipped to the virtual desktop, so a window pushed past a screen edge keeps its visible geometry instead of dropping out of the scene.

`ScreenCaptureService` uses ScreenCaptureKit and captures a single relevant display only after explicit interaction. Captures used for local analysis are aspect-fit to a 1920-pixel longest edge to bound memory and Vision latency. The cap is applied to the display's backing pixel size, taken from its display mode, because ScreenCaptureKit reports points while the stream configuration expects pixels; treating one as the other would capture every Retina display at 1x. Screenshots are optional, and Beacon normally skips visual analysis when Accessibility already provides a matching target. Browser menu, settings, and profile/account guides, menu-bar navigation, and known static-menu Electron applications keep local visual context when permission is available because the next control may be missing, poorly labelled, or present in the Accessibility tree even while visually closed. Accessibility-only guidance remains available when Screen Recording is denied.

`VisionSceneAnalyzer` runs Apple's Vision framework locally. It combines OCR with rectangle detection and light/dark contour analysis, classifying normalized candidates as text, rectangle, circle, icon, or freeform canvas shape. Nearby OCR labels are associated with detected shapes when possible. Sensitive candidates are removed before model context is created, and the image is redacted before it becomes eligible for a privacy preview or provider request.

## Grounding

Models select stable element IDs whenever possible. `AccessibilityGrounder` resolves those IDs to locally known bounds. `VisualGrounder` accepts only validated normalized bounding boxes. `SetOfMarksBuilder` deterministically combines accessible controls with uncovered local-vision candidates, and models can return a mark number that must exist in that exact table. `HybridGrounder` preserves the Accessibility-first priority and resolves validated marks or visual bounds without coupling the overlay to a provider.

The local matcher automatically ranks mark labels, shape types, and spatial phrases such as “circle on the right.” When separately consented OpenAI visual reasoning is enabled, Beacon draws the same marks over the locally redacted image before sending it. The exact outbound image remains visible under Privacy.

The overlay accepts only `GroundedTarget`, so it cannot tell whether a target came from AX, local vision, Set-of-Marks, or a cloud model.

## Instructor lifecycle

The UI has one **Ask Beacon** entry point. `RequestModeClassifier` combines an on-device Natural Language sentence embedding with structural action/explanation evidence and matches against the currently visible scene. Terse interface goals prefer the guide path; explicit explanations retain the one-shot answer path. It returns a scored classification while keeping those internal modes out of the prompt UI.

`InstructorStateMachine` makes each guide step explicit:

```text
idle → capturingScene → understanding → grounding → presenting
     → waitingForChange → verifying → completed
                         ↘ awaitingContextRestore → capturingScene
presenting → awaitingConfirmation → verifying → next step or completed
awaitingContextRestore → verifying   (the user completed the step while Beacon waited)
presenting / waitingForChange / awaitingContextRestore → contextChanged → capturingScene
```

A table-driven test asserts the destination of every legal `(state, event)` pair and that
every other pair is rejected, so an added or removed arrow must be declared there.

Before an instruction reaches the overlay, `SceneFreshnessValidator` recaptures the Accessibility scene and confirms that the application identity, window identity, display geometry, semantic interface, and target still match the scene used for reasoning. Semantic comparison ignores volatile focus and value state and tolerates small tree differences caused by dynamic controls or bounded Accessibility traversal, while still rejecting material interface changes and missing, changed, or disabled targets. It refreshes valid Accessibility bounds and requires a new matching frame for visual targets. Window movement invalidates a visual target. Display attachment, removal, scale, or resolution changes cancel pending work and remove overlays; the next explicit request uses fresh geometry. A stale result is never rendered. If the user already completed the expected step, Beacon verifies it and replans from the new scene. If another app or window becomes active without verified completion, `contextChanged` discards the old target, allows a brief settling interval, and captures fresh context for the same question. Completed-step history remains unchanged. This also applies during menu recovery and is capped at eight context replans per request. Other stale targets enter `awaitingContextRestore` until the required menu or control returns.

Cancellation returns any state to idle. Invalid transitions throw. A Guide response must point to a validated target or explicitly claim completion; a targetless incomplete response gets one local fallback and then fails visibly instead of entering the informational-answer completion path. The visible processing and recovery HUD is a click-through, non-key panel, so it does not dismiss menus or popovers. While a visible guide step or context-recovery request is active, `AccessibilityChangeObserver` listens for focus, value, menu, window, layout, move, and resize notifications. Menu-open callbacks retain only the opened element's short local role and label. `AccessibilityService` also records `AXSelected` menu state because Electron can expose closed-menu descendants and therefore leave the element list unchanged when **Code** opens. Intermediate events in the same window that do not yet satisfy the expected outcome remain in the observation phase. Each typed expected outcome declares whether verification must remain in the current application or may accept another one. Automatically verifying a cross-application handoff requires an expected new window, explicit `mayChange` scope, and the exact destination bundle identifier; same-application is the default. An unverified app/window change instead refreshes guidance without adding a completed step. For navigation-style questions, a same-app, same-window structural change, meaningful local visual change, selected target transition, or labelled notification for the highlighted menu immediately replans the next grounded step, even if a provider incorrectly called the navigation click final. Unrelated menu openings and focus-only noise never do this. Low-rate fallback timers cover applications that do not publish useful events. Each observation window is bounded to ten seconds, polls after one second when notifications are absent, and stops after three consecutive observation errors. Visual verification samples remain local and in memory. Successful verification advances the same guide with completed-step context, up to an eight-step safety limit. A separately typed `completesTaskAfterSuccess` flag lets verified final actions finish without an unnecessary model call or premature completion.

An explicit request holds a user-initiated process activity until its answer or automatically observed guide completes. Manual confirmation releases the activity while waiting for the user. This prevents App Nap from stretching capture and verification latency when Beacon's main window is behind another app or closed; cancellation and every terminal path release the activity.

Each asynchronous operation inherits a request identity. Cancellation, a new request, pausing capture, and privacy-policy changes invalidate that identity. Capture and model results are checked after suspension before they can update the state, retain an image, or present guidance. Capture and model dependencies can be substituted in deterministic lifecycle tests, including providers that ignore task cancellation. Inspector preview generation does not replace a running guide's mark table.

Observation fingerprints include process identity, window identity, titles and presence, display geometry, control values, enabled state, and focus. Window position and size are deliberately excluded: moving or resizing a window does not change what the interface offers. Incomparable or undecodable image samples cannot verify an action. Recovery retries are bounded for both one-shot pointing responses and multi-step guides, and each newly presented step starts with its own allowance. Informational answers are shown in a dismissible status panel with their full text retained in the main window, and never ask the user to confirm a task.

Observation coalesces bursts of Accessibility notifications into at most one capture every 450 ms, and compares a lightweight 64×40 luminance sample before spending a text-recognition and shape pass. The unredacted sample is retained only in a small in-memory cache keyed to the redacted preview captured at the same instant, so subsequent comparisons are raw-to-raw without making an unredacted image provider-eligible. Only a real change of display geometry cancels a request; AppKit also posts screen-parameter changes when the Dock or menu bar changes size.

`StepVerifier` checks typed expected evidence: exact element identity/labels and role, expected value, or an identified new window containing the expected control. It scopes evidence to the relevant window and rejects ambiguous matches. Whole-frame changes, unrelated values/focus, and Save/Cancel sheet closure never prove success. A navigation step whose menu or page visibly changed is replanned instead of entering confirmation. Other insufficient or inherently ambiguous outcomes enter `awaitingConfirmation`; the user chooses **Confirm Result** or **That Didn’t Work** in the menu or Home. A bounded AX-only observer hides stale guidance during this wait, then stops after 30 seconds. No model is called while waiting. Explicit confirmation allows the next step to use the current app, even when its bundle identifier was not predicted. Unverified final completion claims still require confirmation when no next interface appeared. Declining confirmation stops the guide without recording success.

`ApplicationGuidePolicyRegistry` contains guidance-only fixtures for common TextEdit, Preview, Finder, Safari, and System Settings tasks, including the Appearance → Dark path. It uses exact, unambiguous labels and roles, retries missing changes within application-specific limits, and stops with an actionable message when a prerequisite is missing. Preview export explicitly selects PDF and checks the Format value before Save; export success then needs the user to check the saved file. A plain Save sheet also contains exactly one Save button, so the Preview export step is verified by the Format popup only that sheet has, and TextEdit's export step asks the user to confirm rather than accept an ambiguous match. Navigation can be skipped only when its next control is visible, or an explicit state predicate proves that a step is already satisfied; skipped navigation re-evaluates the selected state so an already-satisfied goal completes immediately. Before a recipe has completed any step, an unmatched control defers to the configured model instead of ending the request, because a localized or restructured interface is the usual cause. It never performs the action for the user.

## Providers

`InstructorModel` exposes capabilities and one typed async method. Current adapters are:

- `AccessibilityHeuristicProvider`: deterministic, local, and the automatic fallback;
- `AppleFoundationModelProvider`: the default selection for local language reasoning on supported systems;
- `OpenAIProvider`: optional structured output over the Responses API, with separately consented redacted image input.

`ModelContextBuilder` ranks focused, semantically relevant, actionable controls and enforces strict element and character budgets. It reserves bounded slots for relevant local visual candidates so a large Accessibility tree cannot crowd OCR out of the prompt. When an otherwise unlabelled accessible control overlaps local OCR, Set-of-Marks keeps the stable Accessibility target and fuses the local text label. This prevents large browser or IDE trees from overflowing local context windows without discarding useful visual grounding. Apple output uses a native `@Generable` schema and retries once with a smaller context budget. All model actions are validated against the current scene before rendering. Unknown IDs and rectangles not fully contained by one real display are rejected.

The character budget covers the whole user prompt: question, application/window header, completed-step history, and selected controls. History is bounded and sensitive text is filtered again. OpenAI output decoding handles heterogeneous output items and requires a completed response; a refusal and a truncated response are reported with their own actionable messages rather than as an unreadable response. Apple output treats an empty or placeholder field as absent and validates a target only for a pointing answer, so an explanation is not discarded over an unused field. Model rectangles must fall on a real display, not merely inside the union of all displays. Runtime provider failures use the local matcher and surface the failure to the user. The local matcher cannot infer task completion merely from exhausting its candidates, and its navigation fallback matches whole words so unrelated questions are not routed to the File menu.

## Next milestones

1. Expand application fixtures from real-world, privacy-safe failure reports.
2. Add domain-specific CAD semantics without reading or modifying document data.
3. Exercise Developer ID signing/notarization with the release identity and finish the documented threat model review.
