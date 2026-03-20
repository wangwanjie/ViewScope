# Preview, Host Switching, and Inspector Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove layered-preview overdraw, make host switching clear stale state immediately, repair current Inspector editing, and add a small safe set of new editable properties.

**Architecture:** Make `WorkspaceStore` session-aware and generation-guarded so async responses cannot leak across host switches, simplify layered preview to a single screenshot plane plus vector overlays, and extend the Inspector from a narrow hardcoded subset to a payload-driven model that still respects a strict server-side mutation whitelist. Keep the work incremental: first build test seams and lifecycle protection, then simplify rendering, then repair and extend editing.

**Tech Stack:** AppKit, Combine, Network.framework, Swift Testing, XCTest/XCUITest, local Swift package tests via `swift test`

---

### Task 1: Harden Host Switching and Async Session Lifecycles

**Files:**
- Create: `ViewScope/ViewScope/Services/WorkspaceSessionProtocol.swift`
- Modify: `ViewScope/ViewScope/Services/ViewScopeClientSession.swift`
- Modify: `ViewScope/ViewScope/Services/WorkspaceStore.swift`
- Create: `ViewScope/ViewScopeTests/WorkspaceStoreConnectionLifecycleTests.swift`

- [ ] **Step 1: Write the failing lifecycle tests**

Create `ViewScope/ViewScopeTests/WorkspaceStoreConnectionLifecycleTests.swift` with test doubles that can:

```swift
@Test func switchingHostsClearsVisibleStateBeforeNewCaptureArrives() async throws
@Test func staleCaptureResponseFromPreviousHostIsIgnored() async throws
@Test func staleDetailResponseAfterHostSwitchIsIgnored() async throws
```

Each test should construct `WorkspaceStore` with an injected fake session factory, seed old `capture`/`selectedNodeID`/`selectedNodeDetail`, trigger a host switch, and assert the state is cleared immediately before the fake new session resolves.

- [ ] **Step 2: Run the new store tests and confirm they fail**

Run:

```bash
xcodebuild test -scheme ViewScope -project ViewScope/ViewScope.xcodeproj -destination 'platform=macOS' -only-testing:ViewScopeTests/WorkspaceStoreConnectionLifecycleTests
```

Expected: FAIL because `WorkspaceStore` has no injectable session seam and current `connect(to:)` keeps old state until the new session finishes.

- [ ] **Step 3: Add a testable session abstraction**

Create `WorkspaceSessionProtocol` that covers the exact async surface `WorkspaceStore` uses:

```swift
@MainActor
protocol WorkspaceSessionProtocol: AnyObject {
    var announcement: ViewScopeHostAnnouncement { get }
    func open() async throws -> ViewScopeServerHelloPayload
    func requestCapture() async throws -> ViewScopeCapturePayload
    func requestNodeDetail(nodeID: String) async throws -> ViewScopeNodeDetailPayload
    func highlight(nodeID: String, duration: TimeInterval) async throws
    func applyMutation(nodeID: String, property: ViewScopeEditableProperty) async throws
    func disconnect()
}
```

Make `ViewScopeClientSession` conform and inject a factory into `WorkspaceStore` so tests can supply a fake session.

- [ ] **Step 4: Add generation-guarded connection state**

In `WorkspaceStore`, add a monotonically increasing `connectionGeneration` and a single helper that resets session-scoped state before opening a new host:

```swift
private func prepareForHostSwitch() {
    session?.disconnect()
    session = nil
    autoRefreshTimer?.invalidate()
    autoRefreshTimer = nil
    capture = nil
    selectedNodeID = nil
    selectedNodeDetail = nil
    focusedNodeID = nil
    errorMessage = nil
}
```

Every async response path must capture the current generation and bail out if it no longer matches.

- [ ] **Step 5: Keep mutation/detail flows on the same guardrail**

Update `refreshCapture()`, `selectNode(withID:)`, `highlightCurrentSelection()`, and `applyMutation(nodeID:property:)` so they all short-circuit when their originating generation is stale.

- [ ] **Step 6: Re-run the focused store tests**

Run:

```bash
xcodebuild test -scheme ViewScope -project ViewScope/ViewScope.xcodeproj -destination 'platform=macOS' -only-testing:ViewScopeTests/WorkspaceStoreConnectionLifecycleTests
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add ViewScope/ViewScope/Services/WorkspaceSessionProtocol.swift ViewScope/ViewScope/Services/ViewScopeClientSession.swift ViewScope/ViewScope/Services/WorkspaceStore.swift ViewScope/ViewScopeTests/WorkspaceStoreConnectionLifecycleTests.swift
git commit -m "fix(workspace): guard host switching against stale session state"
```

### Task 2: Simplify Layered Preview Rendering

**Files:**
- Create: `ViewScope/ViewScope/Support/PreviewLayeredRenderPlan.swift`
- Modify: `ViewScope/ViewScope/UI/Workspace/PreviewCanvasView.swift`
- Modify: `ViewScope/ViewScope/UI/Workspace/PreviewPanelController.swift`
- Create: `ViewScope/ViewScopeTests/PreviewLayeredRenderPlanTests.swift`
- Modify: `ViewScope/ViewScopeTests/PreviewLayerTransformTests.swift`

- [ ] **Step 1: Add failing render-plan tests**

Create `ViewScope/ViewScopeTests/PreviewLayeredRenderPlanTests.swift` with pure tests that encode the intended layered behavior:

```swift
@Test func layeredPlanUsesSingleBaseImagePlane() async throws
@Test func layeredPlanGeneratesVectorOverlaysWithoutImageSlices() async throws
@Test func layeredPlanPreservesSelectionDepthForFocusedNode() async throws
```

Use `SampleFixture.capture()` and a helper plan object so the tests do not depend on AppKit drawing.

- [ ] **Step 2: Run the preview tests and confirm the current gap**

Run:

```bash
xcodebuild test -scheme ViewScope -project ViewScope/ViewScope.xcodeproj -destination 'platform=macOS' -only-testing:ViewScopeTests/PreviewLayeredRenderPlanTests -only-testing:ViewScopeTests/PreviewLayerTransformTests
```

Expected: FAIL because no render-plan helper exists and the current layered path still relies on per-node screenshot slices.

- [ ] **Step 3: Extract a pure layered render-plan helper**

Create `PreviewLayeredRenderPlan.swift` with a small model that answers:

```swift
struct PreviewLayeredRenderPlan {
    var baseImageQuad: [CGPoint]
    var overlayQuads: [Overlay]
}
```

Where `Overlay` carries `nodeID`, projected quad, relative depth, and overlay styling inputs only. Do not carry cropped image data in this helper.

- [ ] **Step 4: Remove screenshot-slice overdraw from the canvas**

Update `PreviewCanvasView` so layered mode:

- draws the single perspective-transformed full screenshot plane once,
- falls back to wireframe rectangles when no screenshot exists,
- draws node outlines/fills/selection from `PreviewLayeredRenderPlan`,
- deletes the per-node Core Image crop path from `drawLayeredPreview(for:)`.

- [ ] **Step 5: Keep preview reset behavior aligned with host switching**

Make sure `PreviewPanelController` continues to hide the canvas whenever `store.capture == nil`, so the host-switch clearing in Task 1 immediately removes the previous host image from view.

- [ ] **Step 6: Re-run the focused preview tests**

Run:

```bash
xcodebuild test -scheme ViewScope -project ViewScope/ViewScope.xcodeproj -destination 'platform=macOS' -only-testing:ViewScopeTests/PreviewLayeredRenderPlanTests -only-testing:ViewScopeTests/PreviewLayerTransformTests
```

Expected: PASS.

- [ ] **Step 7: Manual verification**

Build and launch the app with:

```bash
xcodebuild build -scheme ViewScope -project ViewScope/ViewScope.xcodeproj -destination 'platform=macOS'
VIEWSCOPE_PREVIEW_FIXTURE=1 VIEWSCOPE_DISABLE_UPDATES=1 open ViewScope/.derived/Build/Products/Debug/ViewScope.app
```

Verify layered mode rotates smoothly, no duplicate host content is visible, and the previously inconsistent-looking layer is gone.

- [ ] **Step 8: Commit**

```bash
git add ViewScope/ViewScope/Support/PreviewLayeredRenderPlan.swift ViewScope/ViewScope/UI/Workspace/PreviewCanvasView.swift ViewScope/ViewScope/UI/Workspace/PreviewPanelController.swift ViewScope/ViewScopeTests/PreviewLayeredRenderPlanTests.swift ViewScope/ViewScopeTests/PreviewLayerTransformTests.swift
git commit -m "fix(preview): remove layered screenshot overdraw"
```

### Task 3: Repair Existing Inspector Editing End-to-End

**Files:**
- Modify: `ViewScope/ViewScope/UI/Workspace/InspectorPanelController.swift`
- Modify: `ViewScope/ViewScope/UI/Workspace/InspectorViewModels.swift`
- Modify: `ViewScope/ViewScope/Support/SampleFixture.swift`
- Modify: `ViewScopeServer/Sources/ViewScopeServer/ViewScopeSnapshotBuilder.swift`
- Modify: `ViewScopeServer/Sources/ViewScopeServer/ViewScopeInspector.swift`
- Create: `ViewScope/ViewScopeTests/InspectorPanelModelBuilderTests.swift`
- Create: `ViewScopeServer/Tests/ViewScopeServerTests/ViewScopeMutationSupportTests.swift`

- [ ] **Step 1: Add failing app-side inspector tests**

Create `ViewScope/ViewScopeTests/InspectorPanelModelBuilderTests.swift` with payload-driven tests for the currently supported editable keys:

```swift
@Test func builderShowsEditableRowsForCurrentWhitelistedProperties() async throws
@Test func builderKeepsUnknownOrReadOnlyItemsVisibleAsReadOnlyRows() async throws
```

Cover `hidden`, `alpha`, `frame.*`, `bounds.*`, `contentInsets.*`, `backgroundColor`, and `control.value`.

- [ ] **Step 2: Add failing server-side mutation tests**

Create `ViewScopeServer/Tests/ViewScopeServerTests/ViewScopeMutationSupportTests.swift` to prove the server both emits and applies the existing editable set:

```swift
func testDetailPayloadMarksCurrentEditableProperties() throws
func testMutationsApplyForCurrentEditableProperties() throws
```

Use focused AppKit fixtures for a view, a text control, and a scroll view.

- [ ] **Step 3: Run the focused inspector test suites**

Run:

```bash
xcodebuild test -scheme ViewScope -project ViewScope/ViewScope.xcodeproj -destination 'platform=macOS' -only-testing:ViewScopeTests/InspectorPanelModelBuilderTests
swift test --package-path . --filter ViewScopeMutationSupportTests
```

Expected: FAIL because the builder only surfaces a narrow subset and the server does not expose every currently intended editable key consistently.

- [ ] **Step 4: Make the Inspector model builder payload-driven for current properties**

Refactor `InspectorViewModels.swift` so it no longer hardcodes only title/value/hidden/background. Add focused row builders for:

- grouped quad geometry rows,
- single toggle rows,
- single text rows,
- single number rows for editable scalar numbers such as `alpha`.

The builder should preserve unknown items as read-only rows instead of dropping them.

- [ ] **Step 5: Tighten commit and rollback behavior**

In `InspectorPanelController`, keep the existing disable/commit/re-enable flow but make sure all row types share the same contract:

```swift
if !success {
    rowView.resetDisplayedValue()
}
```

Add a dedicated single-number commit path instead of routing scalar numbers through read-only rows.

- [ ] **Step 6: Align the server payload and mutation whitelist**

Update `ViewScopeSnapshotBuilder` and `ViewScopeInspector` so every currently supported editable key appears with matching editable metadata and can round-trip successfully through the mutation endpoint.

- [ ] **Step 7: Refresh the sample fixture**

Update `SampleFixture.detail(for:)` so fixture mode includes representative editable data for the current property set, letting app tests and manual QA run without a live host.

- [ ] **Step 8: Re-run the focused inspector test suites**

Run:

```bash
xcodebuild test -scheme ViewScope -project ViewScope/ViewScope.xcodeproj -destination 'platform=macOS' -only-testing:ViewScopeTests/InspectorPanelModelBuilderTests
swift test --package-path . --filter ViewScopeMutationSupportTests
```

Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add ViewScope/ViewScope/UI/Workspace/InspectorPanelController.swift ViewScope/ViewScope/UI/Workspace/InspectorViewModels.swift ViewScope/ViewScope/Support/SampleFixture.swift ViewScopeServer/Sources/ViewScopeServer/ViewScopeSnapshotBuilder.swift ViewScopeServer/Sources/ViewScopeServer/ViewScopeInspector.swift ViewScope/ViewScopeTests/InspectorPanelModelBuilderTests.swift ViewScopeServer/Tests/ViewScopeServerTests/ViewScopeMutationSupportTests.swift
git commit -m "fix(inspector): repair existing editable property flows"
```

### Task 4: Add the New Low-Risk Editable Properties

**Files:**
- Modify: `ViewScope/ViewScope/UI/Workspace/InspectorViewModels.swift`
- Modify: `ViewScope/ViewScope/UI/Workspace/InspectorPanelController.swift`
- Modify: `ViewScope/ViewScope/Support/SampleFixture.swift`
- Modify: `ViewScopeServer/Sources/ViewScopeServer/ViewScopeSnapshotBuilder.swift`
- Modify: `ViewScopeServer/Sources/ViewScopeServer/ViewScopeInspector.swift`
- Modify: `ViewScope/ViewScopeTests/InspectorPanelModelBuilderTests.swift`
- Modify: `ViewScopeServer/Tests/ViewScopeServerTests/ViewScopeMutationSupportTests.swift`

- [ ] **Step 1: Add failing tests for the new whitelist**

Extend the existing focused tests to cover:

- `title` for windows,
- `toolTip`,
- `enabled`,
- `button.state` for binary-state buttons only,
- `textField.placeholderString`,
- `layer.cornerRadius`,
- `layer.borderWidth`.

Expected initial assertions:

```swift
#expect(propertyIndex.toggleProperty(forKey: "enabled") != nil)
#expect(propertyIndex.textProperty(forKey: "toolTip") != nil)
#expect(propertyIndex.numberProperty(forKey: "layer.cornerRadius") != nil)
```

- [ ] **Step 2: Run the focused tests and confirm the new gap**

Run:

```bash
xcodebuild test -scheme ViewScope -project ViewScope/ViewScope.xcodeproj -destination 'platform=macOS' -only-testing:ViewScopeTests/InspectorPanelModelBuilderTests
swift test --package-path . --filter ViewScopeMutationSupportTests
```

Expected: FAIL because the new properties are not yet emitted and/or mutated.

- [ ] **Step 3: Extend server detail emission**

In `ViewScopeSnapshotBuilder`, emit editable metadata using the existing key naming conventions:

- `title`
- `toolTip`
- `enabled`
- `button.state`
- `textField.placeholderString`
- `layer.cornerRadius`
- `layer.borderWidth`

Only mark `button.state` editable for binary-state buttons. Leave unsupported variants read-only.

- [ ] **Step 4: Extend server mutation handling**

In `ViewScopeInspector`, add validation and AppKit-safe mutation branches for the new keys. Keep the implementation strict:

```swift
case "enabled":
    guard let control = view as? NSControl, let value = property.boolValue else { throw MutationError.invalidValue }
    control.isEnabled = value
```

Apply the same pattern for tooltip, placeholder, binary button state, and layer-backed numeric mutations.

- [ ] **Step 5: Surface the new properties in the client Inspector**

Update `InspectorViewModels.swift` so the new keys map onto existing row types:

- text rows for `toolTip` and `textField.placeholderString`,
- toggle rows for `enabled` and binary `button.state`,
- number rows for `layer.cornerRadius` and `layer.borderWidth`.

- [ ] **Step 6: Refresh fixture data and app tests**

Update `SampleFixture` and the app-side model tests so fixture mode visibly exercises at least one of each new row type.

- [ ] **Step 7: Re-run the focused tests**

Run:

```bash
xcodebuild test -scheme ViewScope -project ViewScope/ViewScope.xcodeproj -destination 'platform=macOS' -only-testing:ViewScopeTests/InspectorPanelModelBuilderTests
swift test --package-path . --filter ViewScopeMutationSupportTests
```

Expected: PASS.

- [ ] **Step 8: Manual Inspector verification**

Using either fixture mode or a live host, verify:

- editing tooltip/text/placeholder rows refreshes the value,
- toggling enabled or button state visibly updates the host control,
- editing corner radius or border width updates layer-backed views,
- rejected values roll back the edited control.

- [ ] **Step 9: Commit**

```bash
git add ViewScope/ViewScope/UI/Workspace/InspectorViewModels.swift ViewScope/ViewScope/UI/Workspace/InspectorPanelController.swift ViewScope/ViewScope/Support/SampleFixture.swift ViewScopeServer/Sources/ViewScopeServer/ViewScopeSnapshotBuilder.swift ViewScopeServer/Sources/ViewScopeServer/ViewScopeInspector.swift ViewScope/ViewScopeTests/InspectorPanelModelBuilderTests.swift ViewScopeServer/Tests/ViewScopeServerTests/ViewScopeMutationSupportTests.swift
git commit -m "feat(inspector): add safe editable property extensions"
```

### Task 5: Run Full Verification and User-Assisted QA

**Files:**
- Verify: `ViewScope/ViewScopeTests`
- Verify: `ViewScope/ViewScopeUITests`
- Verify: `ViewScopeServer/Tests/ViewScopeServerTests`

- [ ] **Step 1: Run the full server package suite**

Run:

```bash
swift test --package-path .
```

Expected: PASS with all `ViewScopeServerTests` green.

- [ ] **Step 2: Run the full macOS app suite**

Run:

```bash
xcodebuild test -scheme ViewScope -project ViewScope/ViewScope.xcodeproj -destination 'platform=macOS'
```

Expected: PASS with `ViewScopeTests` and `ViewScopeUITests` green.

- [ ] **Step 3: Perform local manual QA**

Verify:

- host switching clears the previous preview immediately,
- old host responses do not repaint the new host,
- layered preview no longer shows duplicated content,
- current editable Inspector rows commit and refresh,
- new low-risk Inspector properties behave as expected.

- [ ] **Step 4: Request user-assisted UI verification for hard-to-automate flows**

If trackpad-heavy rotation or live-host mutations are difficult to validate locally, ask the user to run the exact flow and report:

1. whether layered mode still shows duplicate host content,
2. whether switching hosts ever shows the previous host after the first clear,
3. which Inspector edits succeeded, failed, or rolled back.

- [ ] **Step 5: Apply only targeted fixes if QA finds regressions**

If a manual issue appears, add the smallest missing regression test first, then implement the minimum fix for that single issue.

- [ ] **Step 6: Re-run the exact suite that covers any QA-discovered regression**

Use the narrowest matching `xcodebuild` or `swift test --filter ...` command before re-running the full suite if a shared file changed.

- [ ] **Step 7: Commit**

```bash
git add ViewScope ViewScopeServer
git commit -m "test(workspace): verify preview and inspector repair flow"
```
