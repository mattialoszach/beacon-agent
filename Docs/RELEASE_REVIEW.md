# Release review — 2026-09-07

## Release decision

Ready for owner acceptance testing on real applications. **Not yet approved for public
distribution**: the app is still ad-hoc signed and unnotarized, and no license has been
selected. Passing tests and a clean packaging run do not establish end-to-end correctness
across real applications, permissions, displays, or cloud accounts.

This pass audited the codebase across thirteen review dimensions — request lifecycle and
cancellation, coordinates and grounding, providers and credentials, capture and redaction,
the macOS platform layer, overlay and window behavior, guide policy and verification,
packaging, performance, macOS 14 compatibility, test quality, the previous uncommitted
diff, and documentation consistency. Each candidate defect was independently checked by a
reviewer trying to refute it and a reviewer trying to reproduce it; only findings that
survived both were fixed. No live screen data was sent to a cloud model, and every
automated visual test uses synthetic in-memory images.

## Bugs fixed in this pass

| Area | Failure | Fix and evidence |
| --- | --- | --- |
| Multi-display overlays | Overlay panels were built with the `screen:` initializer while passing a global rectangle, so every panel on a secondary display was offset by that display's origin and no guidance was visible there. | Panels are built in global coordinates and their frame is set explicitly. Tests assert the exact frame for secondary and negative-origin displays. |
| Display changes | Any `visibleFrame` change, including the Dock auto-hiding and the menu bar hiding for a full-screen window, cancelled the active request and closed the prompt mid-typing. | The controller keeps a display snapshot and cancels only on a real geometry change. Controller tests cover unchanged displays, an added display, and a scale-only change. |
| Retina capture | ScreenCaptureKit reports points while the stream configuration expects pixels, so every Retina display was captured at 1x and small text was lost to OCR before redaction could see it. | The 1920-pixel cap is applied to the display mode's backing pixel size. Dimension tests document the points-versus-pixels conversion. |
| Sensitive text | Card and phone detection counted digits across the whole OCR line, so a card number sharing a line with a date or order number was neither masked nor filtered out of the prompt. | Candidate substrings are matched and Luhn-checked individually. Stripe, Google, Slack, GitLab, Hugging Face, npm, and complete PEM private-key blocks are covered. Tests verify the PEM body, footer, and derived visual labels are all removed. |
| Secure fields | Secure fields in the application's other visible windows were dropped by the focused-window filter before redaction ran, although the capture covers the whole display. | Secure-field rectangles are collected before the filter and always masked. Tests cover the other-window case and de-duplication. |
| Notification banners | Banners are drawn by Notification Center, so an excluded application's alert reached the capture and, with visual consent, the outbound image. | Notification Center is always excluded from capture. |
| Main-thread stalls | Accessibility reads in the change observer ran on the main run loop with the multi-second system default timeout, so an unresponsive target application froze Escape and the overlay. | A process-wide 0.25 s messaging timeout is set, elements copied for observation are bounded individually, and a timed-out element no longer triggers a per-attribute retry storm. |
| Idle cost | Every observation tick ran whole-display text recognition and contour analysis just to compute a frame difference, and notification bursts drove captures back to back. | A lightweight raw 64×40 luminance sample decides whether anything changed; recognition runs only after that. It is paired privately with the redacted preview so masks cannot create false differences. Captures are coalesced to at most one per 450 ms. |
| Grounding cost | Relevance scoring ran inside sort comparators, so a large accessibility tree scored the same element thousands of times on the main actor. | Scores are computed once per element before sorting. |
| Overlay cost | The cursor monitor publishes at pointer rate and the whole overlay body observed it, re-rasterizing a full-screen canvas on every mouse move; each observation tick also rebuilt every hosting view. | Only a thin fade wrapper observes the cursor, the content subtree is equatable, hosting views are reused, and an unchanged presentation is skipped. |
| Silent failures | A failed request closed the floating panel and wrote to an alert that only exists in the main window, which is usually closed. | Failures are shown beside the pointer and remain dismissible with Escape. |
| Permissions | After a denial, macOS never shows its prompt again, so "Grant Access" did nothing and offered no route forward. | The request opens the relevant Privacy & Security pane and the button relabels itself, with a note that Screen Recording needs a restart. |
| Escape handling | Local key monitors consumed every Escape anywhere in Beacon, so backing out of the Remove-key dialog cancelled the running guide. | Escape still cancels guidance from an ordinary window, but a sheet, alert or dialog keeps its own. |
| Guide dead ends | A recipe whose first control could not be matched, for example on a non-English system, returned a dead-end response and the model was never consulted. | Before a recipe completes any step, an unmatched control defers to the model. A committed recipe still stops with an actionable message. |
| Navigation stopped after one click | An unverified avatar or menu click entered confirmation immediately, so opening Google's account menu left a text message instead of the next arrow. Provider completion claims could also end a navigation flow early. | Navigation-style guides now detect a changed menu, page, or control set and immediately replan the next grounded arrow. Focus-only changes are ignored, and browser guides retain local visual context when permitted. Lifecycle tests reproduce avatar → account menu continuation. |
| Static Electron menus | VS Code can expose menu descendants before the **Code** menu is visibly open, so an `elementAppears` outcome saw the same tree after the click and reported “Beacon did not confirm the step.” | Every navigation step can use the same-window continuation fallback. The observer matches the menu-open callback to the highlighted label, captures `AXSelected`, and keeps local frame context when permitted. The local matcher knows Code → Settings → Theme priority. Regression tests use an identical before/after tree, advance Code → Settings, and reject an unrelated File-menu event. |
| Observation could feel stuck | A missed Accessibility event waited on a three-second poll and retries could leave a guide watching for up to a minute; repeated capture errors silently restarted the wait. | The fallback poll starts after one second, each navigation observation is bounded to ten seconds, and three consecutive observation errors terminate with an actionable message. |
| False verification | The TextEdit export step verified on any new sheet containing a Save button, so an ordinary Save sheet advanced the guide toward saving the wrong format. | Preview's export step verifies on the Format popup only that sheet has; TextEdit's requires user confirmation. |
| Impossible step | The System Settings recipe expected Beacon's permission switch to change to on, which can never happen when it is already on, so the guide always timed out. | The already-enabled state satisfies the step, and a recipe whose remaining steps are satisfied reports completion. |
| Stranded guides | Completing the expected step while Beacon waited for a lost view to return was never recognised, so the guide failed after 60 seconds. A display change during that wait was also ignored. | Recovery verifies the expected outcome and advances the guide; a display change ends the wait. A new state-machine arrow covers this and is tested. |
| False staleness | The semantic fingerprint compared element multisets, but a budget-truncated capture of an unchanged interface differs by far more than the tolerance, dismissing valid guidance. | Captures record truncation and are treated as inconclusive rather than changed or valid. Presentation retries once; observation waits for another capture. Window geometry no longer contributes to the observation fingerprint. |
| Ungroundable targets | A model rectangle inside the union of all displays but on none of them passed validation, so the state machine waited on guidance that could never be drawn. | Rectangles must be fully contained by one real display; merely intersecting one is rejected. |
| Off-screen geometry | A window pushed past a screen edge normalized to nil, so capture fell back to the main display and straddling controls became ungroundable. | Platform extraction clips to the virtual desktop; model rectangles keep strict validation. |
| Apple provider | A non-pointing answer whose unused target field was empty or "None" was thrown away and reported as the provider being unavailable. | Placeholders are normalised and targets are validated only for pointing answers. |
| Cloud errors | Refusals and truncated responses were reported as "unreadable response", and non-JSON error bodies were shown raw. | Refusal and incompleteness have their own actionable messages; other failures use the status description. Offline fixtures cover both. |
| Credentials | Requests used the editable key field rather than the stored key, and a save racing a remove could leave Keychain and the UI disagreeing. Errors surfaced as bare status codes. | Requests use the stored key, credential writes are serialised, every queued save snapshots its submitted draft, and Keychain errors carry readable text and a hint. |
| Local matching | The navigation fallback matched substrings, so "reopen" and "blueprint" pointed at the File menu and shadowed every other intent. | Whole-word matching, with settings evaluated first. |
| Set-of-Marks | Badges centred on a mark's corner were clipped at the image edge, making the number unreadable for menu bar and sidebar marks; marks from another display were drawn at the origin. | Badge centres are clamped inside the bitmap and off-display marks are skipped. |
| Launch robustness | The brand-asset loader fell back to the generated resource accessor, which calls `fatalError` when its bundle is missing, turning a missing image into a crash during launch. | Resource lookup is non-fatal and the resource bundle is now shipped inside the app. |
| Completion message | A guide that finished its task on the eighth step was reported as paused at the safety limit. | Completion is distinguished from the limit in all three paths. |
| Retry accounting | Attempts spent on an earlier step consumed the next step's allowance, stopping a fresh step after one window. | Each newly presented step resets its allowance. |
| Cancellation | Follow-on reasoning after Confirm Result was not stored as the cancellable request, so Escape left a provider call running. | It runs through the request handle like every other reasoning path. |
| Inspector | Refresh always captured the main display, so on a multi-display setup it analysed the wrong screen. | It captures the active window's display, like every other path. |
| Classification | "Where's X" and "Where are X" routed to an informational answer while "Where is X" pointed at the control. | The phrase list covers the contracted and plural forms. |
| Keyboard access | The sidebar was built from plain buttons, so it was not arrow-key navigable and did not expose selection to VoiceOver. | It is a selection-driven list. |
| Exclusion UI | An excluded application that had quit disappeared from the list, so its exclusion could not be removed. | Excluded identifiers are always listed and the list refreshes on launch and quit. |
| Light appearance | The sidebar logo was forced white on a light translucent sidebar, leaving the header blank. | It uses the brand tint. |
| Instruction appearance | The fixed lavender callout looked like a white text box and its arrow chose a target side without regard to the instruction position. | The callout now uses macOS adaptive material with purple content, and arrow layout connects the callout-facing side to the target. Geometry and contrast tests cover it. |
| Prompt focus | The question panel stayed on every Space after the user clicked into another application and could not be dismissed there. | Losing key status closes it. |
| Nested windows | The focused-window filter matched only the immediate parent, so an alert presented over a sheet lost every control and could not be pointed at. | Window relationships are followed transitively, with tests for nesting, unrelated windows and cycles. |
| Stalled elements | An element whose batched read timed out still triggered a second timed-out read for its actions, halving how much of a busy application's interface the traversal could reach. | A timed-out element ends that branch and marks the capture truncated. |

Two defects introduced by this pass were caught by an independent review of its own diff
and fixed: advancing a guide from context recovery tore down the observation that the next
step had just started, leaving the guide visible but permanently unverified; and the shared
verified-step tail appended a second history row instead of resolving the pending one. Both
now have a regression test that was confirmed to fail without the fix.

A later verification found six more edge cases in those changes: partial PEM masking,
truncated freshness reads being accepted as valid, raw frames being compared with redacted
baselines, partially off-display model rectangles, history resolution selecting an older
cancelled request, and queued Keychain saves reading a previous draft. Each now has a
deterministic regression test.

## Test quality fixes

Controller tests no longer touch the real login Keychain. The exclusion assertions were
vacuous because capture permission was stubbed off, making every screenshot path
unreachable; capture is now injectable and the tests grant permission, so the assertions
depend on the exclusion check itself.

## Remaining release prerequisites

### Distribution

The default app is **ad-hoc signed and unnotarized**, and this Mac reports zero valid
code-signing identities. `scripts/release-app.sh` provides `check`, `prepare`, and
`notarize`; the signing and notarization path cannot be validated until a Developer ID
identity and a notarization profile are configured. Exercise it, then test first-launch
Gatekeeper behavior and permission persistence across an update.

An ad-hoc signature is identified only by its code hash, so every rebuild is a different
principal to macOS: Accessibility and Screen Recording must be re-enabled and the Keychain
prompts again. Use a stable signing identity for repeated local testing.

**Select the repository license before distributing binaries or accepting contributions.**

### Verification the owner must still do

Compilation and unit tests do not establish runtime behavior. Verify on real systems:
macOS 14 and Intel hardware, physical multi-display layouts at mixed scales, live
Accessibility and ScreenCaptureKit behavior in real applications, and a real OpenAI
account in each consent mode.

## Known limitations

Overlay panels sit above the menu bar so guidance can point at menu bar items and open
menus, which is a core capability. A consequence is that the spotlight scrim also dims
Beacon's own menu while an overlay is visible. The menu stays fully usable because the
overlay is click-through.

## Owner test plan

1. Build and open `.build/Beacon.app`. Try the shortcut with the main window open and closed.
2. With Accessibility granted and Screen Recording denied, locate Print in TextEdit, then ask “Where do I change to dark mode?” in System Settings. Beacon must point to Appearance, continue to Dark, render purple words and an arrow for both steps, and stop only after the Dark value is selected. Also change a checkbox and confirm its value change is observed without a screenshot.
3. Press Escape during capture, reasoning, visible guidance, and recovery, then immediately start another question. No old answer or overlay may reappear. Repeat with Pause Screen Access and Dismiss Overlay. Open the Models tab, start removing the API key, and press Escape: the dialog closes and any guide keeps running.
4. Ask an informational question. Read the answer beside the pointer and in History. It must not ask you to confirm anything.
5. Deny a permission, then use Grant Access in Permissions: System Settings must open at the right pane.
6. With Dock auto-hide on, start a guide and reveal the Dock; the guide must continue. Then disconnect or rearrange a display: the guide must stop and say so.
7. Open and close menus, switch apps, move a window, and switch between two windows with the same title during a guide. In Chrome, ask how to change your Google profile picture: after clicking the avatar, Beacon must replace the first overlay with an arrow to the next visible account control rather than stopping at a message. In VS Code, ask “How can I change my VSCode theme?”, open the highlighted Code menu, and verify that Beacon immediately points to the next menu command. Opening File instead must not advance. Clicking without an interface change must not falsely advance. Record any wrong target or unexpected progression.
8. Exercise TextEdit export and Print, Finder New Folder, Safari Settings, and System Settings permissions, with the permission both off and already on. Cancel a save dialog and change an unrelated control while waiting; these must leave the guide unconfirmed.
9. Test Preview PDF export from both a PDF and a PNG or JPEG source and inspect the actual saved file before choosing Confirm Result.
10. Test multiple displays at mixed scales, including a display to the left of and above the primary. Guidance must appear on the display holding the target and the unrelated screen must not dim.
11. Use synthetic private data to check password, email, phone, payment-card, API-key, and complete multi-line PEM masks, including a card number on a line with other numbers. Put an excluded app on the same display as the active app and confirm no screenshot is taken. Trigger a notification from an excluded app during a capture and confirm the banner is absent.
12. With your own consent and key, test text-only OpenAI, then the separate image opt-in and the exact Privacy preview. Type a partial key without saving and confirm the stored key is still used. Test offline operation and an invalid key.
13. Switch macOS between Light and Dark appearance while guidance is visible. The instruction surface must follow the system material and purple words/arrows must remain readable.
14. Save, edit, remove, and re-add a disposable test key. Also queue two rapid saves and confirm the newer draft wins. Restart the app and check persistence.

## Automated evidence

Review machine: Apple Silicon, macOS 26.6.2, Swift 6.3.3, macOS 26.5 SDK, deployment
target macOS 14.

| Check | Result |
| --- | --- |
| `swift build` | Succeeds with no warnings. |
| `swift test` | 283 tests, zero failures; the real-model test is skipped by default. |
| `swift test --parallel` | Passes; the suite is safe to run concurrently. |
| `BEACON_RUN_MODEL_TESTS=1 swift test` | The on-device Apple Foundation Model test passes. |
| `./scripts/build-app.sh` | Host release packaging passed. |
| `BEACON_BUILD_UNIVERSAL=1 ./scripts/build-app.sh` | Built and packaged for `x86_64` and `arm64`. |
| `codesign --verify --deep --strict .build/Beacon.app` | Passed. Signature is ad-hoc; no TeamIdentifier. |
| `plutil -lint` on the packaged Info.plist | Passed. |
| `zsh -n` on both scripts | Passed. |
| Launch smoke test | The packaged universal app launches and stays running with no crash or error in its log. |
| `otool -l` on the packaged binary | FoundationModels is a weak link, so the binary loads on macOS 14 and 15. |

Successful Developer ID signing, notarization, a live OpenAI round trip, and real-app
acceptance were not exercised. The baseline for this pass was 155 tests; it is now 283.
