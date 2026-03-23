# Lookin Alignment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Align ViewScope’s hierarchy, event affordances, layered preview, and helper console with the approved Lookin-style behavior, including wrapper filtering, generation-based 3D planes, and protocol v2 console support.

**Architecture:** Extend the shared bridge and snapshot builder first so the client has stable protocol v2 data: capture-scoped preview bitmaps, exact controller-root metadata, and console target/invocation payloads. Then update the client in layers: persisted wrapper-filter state and tree presentation, generation-based layered planning and parallel transforms, plane-content rendering, and finally the console panel wired to the new protocol.

**Tech Stack:** Swift, AppKit, Combine, SnapKit, XCTest/Testing, Network.framework, ViewScopeServer bridge protocol

---

## File Structure

- Modify: `ViewScopeServer/Sources/ViewScopeServer/ViewScopeBridge.swift`
  Purpose: Define protocol v2 payloads for `captureID`, capture preview bitmaps, console targets, remote object references, console invoke request/response, and new message kinds.
- Modify: `ViewScopeServer/Sources/ViewScopeServer/ViewScopeInspector.swift`
  Purpose: Route new console invoke messages, validate capture-scoped handles, and return protocol v2 responses.
- Modify: `ViewScopeServer/Sources/ViewScopeServer/ViewScopeSnapshotBuilder.swift`
  Purpose: Tighten exact controller-root tagging, mint capture-scoped preview bitmaps, and expose console targets for selected nodes.
- Modify: `ViewScopeServer/Tests/ViewScopeServerTests/ViewScopeServerTests.swift`
  Purpose: Cover exact controller-root tagging, preview bitmap metadata, console target emission, and stale-handle rules.
- Modify: `ViewScope/ViewScope/Services/WorkspaceSessionProtocol.swift`
  Purpose: Expose protocol v2 capture and console APIs to the app.
- Modify: `ViewScope/ViewScope/Services/ViewScopeClientSession.swift`
  Purpose: Send/receive protocol v2 messages including console invocation.
- Modify: `ViewScope/ViewScope/Services/WorkspaceStore.swift`
  Purpose: Persist wrapper filtering, normalize selection when filtering changes, and manage console target/history state.
- Modify: `ViewScope/ViewScope/Services/AppSettings.swift`
  Purpose: Persist wrapper-filter preference across launches and expose the default-on setting.
- Modify: `ViewScope/ViewScope/Localization/L10n.swift`
  Purpose: Surface new wrapper-filter and console strings.
- Modify: `ViewScope/ViewScope/en.lproj/Localizable.strings`
  Purpose: English strings for wrapper filter, console, and stale-handle errors.
- Modify: `ViewScope/ViewScope/zh-Hans.lproj/Localizable.strings`
  Purpose: Simplified Chinese strings for wrapper filter, console, and stale-handle errors.
- Modify: `ViewScope/ViewScope/zh-Hant.lproj/Localizable.strings`
  Purpose: Traditional Chinese strings for wrapper filter, console, and stale-handle errors.
- Modify: `ViewScope/ViewScope/UI/Workspace/ViewTreePanelController.swift`
  Purpose: Title suffix rendering, wrapper-filter toggle UI, left handler pill, selected-state styling, and wider popup list.
- Modify: `ViewScope/ViewScope/UI/Workspace/InspectorViewModels.swift`
  Purpose: Keep controller/action metadata presentation aligned with the new node semantics where needed.
- Modify: `ViewScope/ViewScope/Support/PreviewLayeredRenderPlan.swift`
  Purpose: Replace per-node depth allocation with generation-based plane planning and exclusive pixel ownership metadata.
- Modify: `ViewScope/ViewScope/Support/PreviewLayerTransform.swift`
  Purpose: Replace perspective projection with affine/parallel plane transforms and updated hit-testing helpers.
- Modify: `ViewScope/ViewScope/UI/Workspace/PreviewCanvasView.swift`
  Purpose: Render capture-scope plane bitmaps with punch-out masks, optional borders, and new hit-testing.
- Modify: `ViewScope/ViewScope/UI/Workspace/PreviewPanelController.swift`
  Purpose: Consume capture preview assets instead of selected-detail screenshots and surface console entry points if needed.
- Create: `ViewScope/ViewScope/UI/Workspace/ConsolePanelController.swift`
  Purpose: Implement the Lookin-style helper console panel shell, history list, input row, clear button, and target selector.
- Create: `ViewScope/ViewScope/UI/Workspace/ConsoleViewModels.swift`
  Purpose: Hold console row models, target-descriptor models, and sync/selection logic kept out of view code.
- Modify: `ViewScope/ViewScopeTests/ViewScopeTests.swift`
  Purpose: Tree-title, wrapper-filter, search, and console-model tests.
- Modify: `ViewScope/ViewScopeTests/PreviewLayeredRenderPlanTests.swift`
  Purpose: Generation-plane planning tests.
- Modify: `ViewScope/ViewScopeTests/PreviewLayerTransformTests.swift`
  Purpose: Parallel-transform tests and hit-testing expectations.
- Modify: `ViewScope/ViewScope/Support/SampleFixture.swift`
  Purpose: Provide protocol v2 fixture data including preview bitmaps and console targets.

### Task 1: Add Protocol V2 Bridge Types

**Files:**
- Modify: `ViewScopeServer/Sources/ViewScopeServer/ViewScopeBridge.swift`
- Test: `ViewScopeServer/Tests/ViewScopeServerTests/ViewScopeServerTests.swift`

- [ ] **Step 1: Write the failing bridge tests**

Add tests that construct and round-trip:

```swift
let bitmap = ViewScopePreviewBitmap(
    rootNodeID: "window-0",
    pngBase64: "abc",
    size: .init(width: 1200, height: 800),
    capturedAt: Date(),
    scale: 2
)
let target = ViewScopeRemoteObjectReference(
    captureID: "capture-1",
    objectID: "obj-1",
    kind: .viewController,
    className: "Demo.RootViewController",
    address: "0x123",
    sourceNodeID: "window-0-view-0"
)
let message = ViewScopeMessage(
    kind: .consoleInvokeResponse,
    consoleInvokeResponse: .init(
        submittedExpression: "viewDidAppear",
        target: target,
        resultDescription: "<Demo.RootViewController: 0x123>",
        returnedObject: ViewScopeConsoleTargetDescriptor(
            reference: target,
            title: "<Demo.RootViewController: 0x123>",
            subtitle: "viewDidAppear"
        ),
        errorMessage: nil
    )
)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path ViewScopeServer --filter ViewScopeServerTests`
Expected: FAIL with missing protocol-v2 types or message cases.

- [ ] **Step 3: Write minimal bridge implementation**

Add:

```swift
public let viewScopeCurrentProtocolVersion = 2

public struct ViewScopePreviewBitmap: Codable, Sendable, Hashable { ... }
public struct ViewScopeRemoteObjectReference: Codable, Sendable, Hashable { ... }
public struct ViewScopeConsoleTargetDescriptor: Codable, Sendable, Hashable { ... }
public struct ViewScopeConsoleInvokeRequestPayload: Codable, Sendable, Hashable { ... }
public struct ViewScopeConsoleInvokeResponsePayload: Codable, Sendable, Hashable { ... }
```

Extend `ViewScopeCapturePayload` with `captureID`, extend `ViewScopeNodeDetailPayload`, and extend `ViewScopeMessage.Kind`.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path ViewScopeServer --filter ViewScopeServerTests`
Expected: PASS for bridge serialization coverage.

- [ ] **Step 5: Commit**

```bash
git add ViewScopeServer/Sources/ViewScopeServer/ViewScopeBridge.swift ViewScopeServer/Tests/ViewScopeServerTests/ViewScopeServerTests.swift
git commit -m "feat: add protocol v2 bridge payloads"
```

### Task 2: Build Capture Preview Assets And Exact Controller Targets

**Files:**
- Modify: `ViewScopeServer/Sources/ViewScopeServer/ViewScopeSnapshotBuilder.swift`
- Test: `ViewScopeServer/Tests/ViewScopeServerTests/ViewScopeServerTests.swift`

- [ ] **Step 1: Write the failing snapshot tests**

Add tests asserting:

```swift
#expect(capture.previewBitmaps.count == 1)
#expect(capture.previewBitmaps.first?.rootNodeID == "window-0")
#expect(node.rootViewControllerClassName == "Demo.RootViewController")
#expect(descendant.rootViewControllerClassName == nil)
#expect(detail.consoleTargets.map(\.reference.kind).contains(.view))
#expect(detail.consoleTargets.map(\.reference.kind).contains(.viewController))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path ViewScopeServer --filter ViewScopeServerTests`
Expected: FAIL because capture preview bitmaps and console targets are absent or controller tagging is too broad.

- [ ] **Step 3: Write minimal snapshot-builder implementation**

Implement:

```swift
let captureID = UUID().uuidString
if let image {
    let previewBitmap = ViewScopePreviewBitmap(
        rootNodeID: windowID,
        pngBase64: ViewScopeImageEncoder().base64PNG(image) ?? "",
        size: image.size.viewScopeSize,
        capturedAt: Date(),
        scale: image.recommendedLayerContentsScale(0)
    )
    previewBitmaps.append(previewBitmap)
}
```

Tighten controller ownership to only mark `controller.view === child`, write `captureID` into the capture payload, and create `consoleTargets` from the selected node’s live references.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path ViewScopeServer --filter ViewScopeServerTests`
Expected: PASS for preview bitmap and exact-target metadata.

- [ ] **Step 5: Commit**

```bash
git add ViewScopeServer/Sources/ViewScopeServer/ViewScopeSnapshotBuilder.swift ViewScopeServer/Tests/ViewScopeServerTests/ViewScopeServerTests.swift
git commit -m "feat: add capture preview assets and console targets"
```

### Task 3: Route Console Invocation On The Server

**Files:**
- Modify: `ViewScopeServer/Sources/ViewScopeServer/ViewScopeInspector.swift`
- Modify: `ViewScopeServer/Sources/ViewScopeServer/ViewScopeSnapshotBuilder.swift`
- Test: `ViewScopeServer/Tests/ViewScopeServerTests/ViewScopeServerTests.swift`

- [ ] **Step 1: Write the failing console-invoke tests**

Add tests for:

```swift
#expect(response.kind == .consoleInvokeResponse)
#expect(response.consoleInvokeResponse?.resultDescription.contains("Demo.Target") == true)
#expect(response.consoleInvokeResponse?.errorMessage == nil)
#expect(staleResponse.kind == .consoleInvokeResponse)
#expect(staleResponse.consoleInvokeResponse?.errorMessage?.isEmpty == false)
```

Use a fixture target object with a zero-argument selector and a stale `captureID` request.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path ViewScopeServer --filter ViewScopeServerTests`
Expected: FAIL because the inspector cannot route console-invoke requests.

- [ ] **Step 3: Write minimal server routing**

Add a handler branch like:

```swift
case .consoleInvokeRequest:
    handleConsoleInvokeRequest(message: message)
```

Validate `captureID`, resolve the live object, reject expressions containing `:` or `.`, invoke zero-argument selectors or property-like lookups, and return `ViewScopeConsoleInvokeResponsePayload`.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path ViewScopeServer --filter ViewScopeServerTests`
Expected: PASS for success and stale-handle paths.

- [ ] **Step 5: Commit**

```bash
git add ViewScopeServer/Sources/ViewScopeServer/ViewScopeInspector.swift ViewScopeServer/Sources/ViewScopeServer/ViewScopeSnapshotBuilder.swift ViewScopeServer/Tests/ViewScopeServerTests/ViewScopeServerTests.swift
git commit -m "feat: add server console invocation support"
```

### Task 4: Expose Protocol V2 In Client Session And Fixtures

**Files:**
- Modify: `ViewScope/ViewScope/Services/WorkspaceSessionProtocol.swift`
- Modify: `ViewScope/ViewScope/Services/ViewScopeClientSession.swift`
- Modify: `ViewScope/ViewScope/Support/SampleFixture.swift`
- Test: `ViewScope/ViewScopeTests/ViewScopeTests.swift`

- [ ] **Step 1: Write the failing client-session tests**

Add fixture/model tests that require:

```swift
#expect(SampleFixture.capture().previewBitmaps.isEmpty == false)
#expect(SampleFixture.detail(for: "window-0-view-0").consoleTargets.isEmpty == false)
```

and compile-time coverage for:

```swift
func invokeConsole(target: ViewScopeRemoteObjectReference, expression: String) async throws -> ViewScopeConsoleInvokeResponsePayload
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project ViewScope/ViewScope.xcodeproj -scheme ViewScope -destination 'platform=macOS' -only-testing:ViewScopeTests/ViewScopeTests`
Expected: FAIL with missing capture fixtures or session protocol methods.

- [ ] **Step 3: Write minimal client-session implementation**

Extend the session protocol and session client:

```swift
func requestCapture() async throws -> ViewScopeCapturePayload
func requestNodeDetail(nodeID: String) async throws -> ViewScopeNodeDetailPayload
func invokeConsole(target: ViewScopeRemoteObjectReference, expression: String) async throws -> ViewScopeConsoleInvokeResponsePayload
```

Update `SampleFixture` to provide preview bitmaps and console targets.

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project ViewScope/ViewScope.xcodeproj -scheme ViewScope -destination 'platform=macOS' -only-testing:ViewScopeTests/ViewScopeTests`
Expected: PASS for fixture and session-API coverage.

- [ ] **Step 5: Commit**

```bash
git add ViewScope/ViewScope/Services/WorkspaceSessionProtocol.swift ViewScope/ViewScope/Services/ViewScopeClientSession.swift ViewScope/ViewScope/Support/SampleFixture.swift ViewScope/ViewScopeTests/ViewScopeTests.swift
git commit -m "feat: wire protocol v2 into client session"
```

### Task 5: Persist Wrapper Filtering And Tree Presentation

**Files:**
- Modify: `ViewScope/ViewScope/Services/WorkspaceStore.swift`
- Modify: `ViewScope/ViewScope/Services/AppSettings.swift`
- Modify: `ViewScope/ViewScope/UI/Workspace/ViewTreePanelController.swift`
- Modify: `ViewScope/ViewScope/Localization/L10n.swift`
- Modify: `ViewScope/ViewScope/en.lproj/Localizable.strings`
- Modify: `ViewScope/ViewScope/zh-Hans.lproj/Localizable.strings`
- Modify: `ViewScope/ViewScope/zh-Hant.lproj/Localizable.strings`
- Test: `ViewScope/ViewScopeTests/ViewScopeTests.swift`

- [ ] **Step 1: Write the failing tree/filter tests**

Add tests asserting:

```swift
#expect(ViewTreeNodePresentation.classText(for: node) == "NSView Demo.RootViewController.view")
#expect(filteredRoots.count == 0) // for a known wrapper-only root when filtering is on
#expect(unfilteredRoots.count == 1)
```

Add a store-level test for default `showsSystemWrapperViews == false`.

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project ViewScope/ViewScope.xcodeproj -scheme ViewScope -destination 'platform=macOS' -only-testing:ViewScopeTests/ViewScopeTests`
Expected: FAIL because wrapper-filter state and title suffix behavior do not exist.

- [ ] **Step 3: Write minimal tree/store implementation**

Add persisted state in `AppSettings` and visible-tree filtering in the store:

```swift
@Published var showsSystemWrapperViews: Bool {
    didSet { defaults.set(showsSystemWrapperViews, forKey: Keys.showsSystemWrapperViews) }
}
```

```swift
@Published private(set) var showsSystemWrapperViews = AppSettings.shared.showsSystemWrapperViews

func setShowsSystemWrapperViews(_ value: Bool) {
    showsSystemWrapperViews = value
    settings.showsSystemWrapperViews = value
    Task { await refreshCapture(forceReloadSelectionDetail: true, clearingVisibleState: false) }
}
```

Update tree title formatting to emit `"<ViewClass> <ControllerClass>.view"` only for exact controller-root nodes. Add a visible toggle in the hierarchy UI.

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project ViewScope/ViewScope.xcodeproj -scheme ViewScope -destination 'platform=macOS' -only-testing:ViewScopeTests/ViewScopeTests`
Expected: PASS for title suffix and wrapper-filter behavior.

- [ ] **Step 5: Commit**

```bash
git add ViewScope/ViewScope/Services/AppSettings.swift ViewScope/ViewScope/Services/WorkspaceStore.swift ViewScope/ViewScope/UI/Workspace/ViewTreePanelController.swift ViewScope/ViewScope/Localization/L10n.swift ViewScope/ViewScope/en.lproj/Localizable.strings ViewScope/ViewScope/zh-Hans.lproj/Localizable.strings ViewScope/ViewScope/zh-Hant.lproj/Localizable.strings ViewScope/ViewScopeTests/ViewScopeTests.swift
git commit -m "feat: add wrapper filtering and Lookin tree titles"
```

### Task 6: Finish Handler Pill And Popup Behavior

**Files:**
- Modify: `ViewScope/ViewScope/UI/Workspace/ViewTreePanelController.swift`
- Test: `ViewScope/ViewScopeTests/ViewScopeTests.swift`

- [ ] **Step 1: Write the failing event-affordance tests**

Add row-presentation tests for:

```swift
#expect(metrics.cornerRadius == 5)
#expect(metrics.leadingAccessory == .handlers)
#expect(selectedAppearance.foreground != normalAppearance.foreground)
```

Use a node with control action and gesture handlers.

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project ViewScope/ViewScope.xcodeproj -scheme ViewScope -destination 'platform=macOS' -only-testing:ViewScopeTests/ViewScopeTests`
Expected: FAIL because the current row/popup behavior does not expose these Lookin-specific metrics.

- [ ] **Step 3: Write minimal event UI implementation**

Implement:

```swift
handlersButton.layer?.cornerRadius = 5
handlersButtonLeading = 2
if isSelected { useSelectedPalette() } else { useNormalPalette() }
popover.contentSize = NSSize(width: 360, height: min(calculatedHeight, 360))
```

Move the pill to the far left, widen the popup, and switch to a scrollable list document view.

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project ViewScope/ViewScope.xcodeproj -scheme ViewScope -destination 'platform=macOS' -only-testing:ViewScopeTests/ViewScopeTests`
Expected: PASS for row metrics and popup sizing decisions.

- [ ] **Step 5: Commit**

```bash
git add ViewScope/ViewScope/UI/Workspace/ViewTreePanelController.swift ViewScope/ViewScopeTests/ViewScopeTests.swift
git commit -m "feat: align event handler affordances with Lookin"
```

### Task 7: Rebuild Layered Plan And Transform

**Files:**
- Modify: `ViewScope/ViewScope/Support/PreviewLayeredRenderPlan.swift`
- Modify: `ViewScope/ViewScope/Support/PreviewLayerTransform.swift`
- Modify: `ViewScope/ViewScope/Support/SampleFixture.swift`
- Test: `ViewScope/ViewScopeTests/PreviewLayeredRenderPlanTests.swift`
- Test: `ViewScope/ViewScopeTests/PreviewLayerTransformTests.swift`

- [ ] **Step 1: Write the failing layered-plan tests**

Replace the old expectations with generation-based assertions such as:

```swift
#expect(plan.plane(for: "window-0")?.index == 0)
#expect(plan.plane(for: "window-0-view-0")?.index == 1)
#expect(plan.plane(for: "window-0-view-1")?.index == 1)
#expect(plan.plane(for: "window-0-view-1-2")?.index == 2)
```

Add transform tests asserting parallel behavior:

```swift
#expect(projected.maxX - projected.minX == rect.width * expectedScale)
#expect(noPerspectiveDivide == true)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project ViewScope/ViewScope.xcodeproj -scheme ViewScope -destination 'platform=macOS' -only-testing:ViewScopeTests/PreviewLayeredRenderPlanTests -only-testing:ViewScopeTests/PreviewLayerTransformTests`
Expected: FAIL because the current plan and transform are per-node and perspective-based.

- [ ] **Step 3: Write minimal planning/transform implementation**

Introduce a plan model like:

```swift
struct PreviewLayerPlane {
    let index: Int
    let nodeIDs: [String]
    let punchOutNodeIDs: [String]
}
```

and an affine transform like:

```swift
func projectedQuad(for rect: CGRect, planeIndex: Int, canvasSize: CGSize) -> [CGPoint] {
    rect.applying(affineTransform(for: planeIndex, canvasSize: canvasSize)).quad
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project ViewScope/ViewScope.xcodeproj -scheme ViewScope -destination 'platform=macOS' -only-testing:ViewScopeTests/PreviewLayeredRenderPlanTests -only-testing:ViewScopeTests/PreviewLayerTransformTests`
Expected: PASS for generation allocation and parallel-transform expectations.

- [ ] **Step 5: Commit**

```bash
git add ViewScope/ViewScope/Support/PreviewLayeredRenderPlan.swift ViewScope/ViewScope/Support/PreviewLayerTransform.swift ViewScope/ViewScope/Support/SampleFixture.swift ViewScope/ViewScopeTests/PreviewLayeredRenderPlanTests.swift ViewScope/ViewScopeTests/PreviewLayerTransformTests.swift
git commit -m "feat: add generation-based layered planning"
```

### Task 8: Render Plane Content With Punch-Outs

**Files:**
- Modify: `ViewScope/ViewScope/UI/Workspace/PreviewCanvasView.swift`
- Modify: `ViewScope/ViewScope/UI/Workspace/PreviewPanelController.swift`
- Modify: `ViewScope/ViewScope/Services/WorkspaceStore.swift`
- Test: `ViewScope/ViewScopeTests/ViewScopeTests.swift`

- [ ] **Step 1: Write the failing preview-source tests**

Add tests covering:

```swift
#expect(resolvedPreviewBitmap.rootNodeID == "window-0")
#expect(detailScreenshotIsNotRequired == true)
#expect(flatFallbackUsesDetailScreenshot == true)
#expect(layeredPreviewDisablesContentWhenBitmapMissing == true)
#expect(selectionHitTestUsesPlaneGeometry == true)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project ViewScope/ViewScope.xcodeproj -scheme ViewScope -destination 'platform=macOS' -only-testing:ViewScopeTests/ViewScopeTests`
Expected: FAIL because preview rendering still depends on selected-detail screenshots and old overlay quads.

- [ ] **Step 3: Write minimal plane-rendering implementation**

Update the preview pipeline to:

```swift
let bitmap = capture.previewBitmap(for: rootNodeID)
if let bitmap {
    let planeImage = composePlaneImage(bitmap: bitmap, nodeIDs: plane.nodeIDs, punchOutNodeIDs: plane.punchOutNodeIDs)
    drawPlaneImage(planeImage, quad: transform.projectedQuad(...))
} else {
    drawLayeredWireframeFallback(...)
}
```

Remove the old bottom screenshot plane and use capture-scope bitmaps for both flat and layered paths. If the active root lacks a capture bitmap, use a same-root detail screenshot only as a temporary flat fallback; otherwise fall back to wireframe and disable layered-content rendering for that root.

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project ViewScope/ViewScope.xcodeproj -scheme ViewScope -destination 'platform=macOS' -only-testing:ViewScopeTests/ViewScopeTests`
Expected: PASS for preview-source and selection behavior.

- [ ] **Step 5: Commit**

```bash
git add ViewScope/ViewScope/UI/Workspace/PreviewCanvasView.swift ViewScope/ViewScope/UI/Workspace/PreviewPanelController.swift ViewScope/ViewScope/Services/WorkspaceStore.swift ViewScope/ViewScopeTests/ViewScopeTests.swift
git commit -m "feat: render layered preview from capture plane content"
```

### Task 9: Add Lookin-Style Console Panel

**Files:**
- Create: `ViewScope/ViewScope/UI/Workspace/ConsolePanelController.swift`
- Create: `ViewScope/ViewScope/UI/Workspace/ConsoleViewModels.swift`
- Modify: `ViewScope/ViewScope/Services/WorkspaceStore.swift`
- Modify: `ViewScope/ViewScope/UI/Workspace/PreviewPanelController.swift`
- Modify: `ViewScope/ViewScope/Localization/L10n.swift`
- Modify: `ViewScope/ViewScope/en.lproj/Localizable.strings`
- Modify: `ViewScope/ViewScope/zh-Hans.lproj/Localizable.strings`
- Modify: `ViewScope/ViewScope/zh-Hant.lproj/Localizable.strings`
- Test: `ViewScope/ViewScopeTests/ViewScopeTests.swift`

- [ ] **Step 1: Write the failing console-model tests**

Add tests for:

```swift
#expect(model.currentTarget?.reference.kind == .view)
#expect(model.autoSync)
model.selectRecentTarget(...)
#expect(model.autoSync == false)
#expect(model.isInputEnabled == false) // while detail is loading or target is stale
#expect(model.currentTarget == nil) // after disconnect
#expect(model.recentTargets.isEmpty) // after disconnect
#expect(model.historyRows.isEmpty == false) // textual history survives disconnect
#expect(model.manualTargetClearsOnCaptureRefreshWhenStale == true)
#expect(model.rows.last?.kind == .return)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project ViewScope/ViewScope.xcodeproj -scheme ViewScope -destination 'platform=macOS' -only-testing:ViewScopeTests/ViewScopeTests`
Expected: FAIL because no console model or target-state machine exists.

- [ ] **Step 3: Write minimal console implementation**

Create:

```swift
struct ConsoleRowModel { ... }
@MainActor final class ConsolePanelController: NSViewController { ... }
```

Wire store actions for:

```swift
func submitConsoleExpression(_ expression: String) async
func selectConsoleTarget(_ target: ViewScopeConsoleTargetDescriptor)
func clearConsoleHistory()
func setConsoleAutoSync(_ enabled: Bool)
```

Display input/history UI and a target-selection popup consistent with the spec, including `detailLoading`, `detailUnavailable`, and stale-`captureID` input-disable states.
Also implement disconnect and capture-refresh invalidation rules:

```swift
func handleDisconnect() {
    currentTarget = nil
    recentTargets.removeAll()
    isInputEnabled = false
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project ViewScope/ViewScope.xcodeproj -scheme ViewScope -destination 'platform=macOS' -only-testing:ViewScopeTests/ViewScopeTests`
Expected: PASS for console target-sync and history rules.

- [ ] **Step 5: Commit**

```bash
git add ViewScope/ViewScope/UI/Workspace/ConsolePanelController.swift ViewScope/ViewScope/UI/Workspace/ConsoleViewModels.swift ViewScope/ViewScope/Services/WorkspaceStore.swift ViewScope/ViewScope/UI/Workspace/PreviewPanelController.swift ViewScope/ViewScope/Localization/L10n.swift ViewScope/ViewScope/en.lproj/Localizable.strings ViewScope/ViewScope/zh-Hans.lproj/Localizable.strings ViewScope/ViewScope/zh-Hant.lproj/Localizable.strings ViewScope/ViewScopeTests/ViewScopeTests.swift
git commit -m "feat: add Lookin-style helper console"
```

### Task 10: Full Verification Pass

**Files:**
- Modify: `READMEAssets/main-window.png` only if screenshot baselines are intentionally updated
- Modify: `READMEAssets/preferences.png` only if screenshot baselines are intentionally updated

- [ ] **Step 1: Run focused server verification**

Run: `swift test --package-path ViewScopeServer --filter ViewScopeServerTests`
Expected: PASS for protocol v2, snapshot, and console invocation coverage.

- [ ] **Step 2: Run focused app verification**

Run: `xcodebuild test -project ViewScope/ViewScope.xcodeproj -scheme ViewScope -destination 'platform=macOS'`
Expected: PASS for tree, preview, and console tests.

- [ ] **Step 3: Run build verification**

Run: `xcodebuild build -project ViewScope/ViewScope.xcodeproj -scheme ViewScope -destination 'platform=macOS'`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Manual verification checklist**

Verify on a live host:

```text
1. Tree row shows "NSView FooViewController.view" only on exact controller-root nodes.
2. Wrapper filter defaults to on, toggle is visible, and toggling refreshes the host.
3. Handler pill is leftmost, radius 5, and selected-row colors remain readable.
4. Popup is wide enough and scrolls with many handlers.
5. Layered preview uses sibling planes, not per-node planes.
6. Layered preview shows actual content on planes with punch-out behavior.
7. Console auto-sync, manual target selection, and stale-handle invalidation behave per spec.
```

- [ ] **Step 5: Commit verification-only asset updates if needed**

```bash
git add READMEAssets/main-window.png READMEAssets/preferences.png
git commit -m "test: refresh ViewScope screenshots" # only if screenshot outputs changed intentionally
```
