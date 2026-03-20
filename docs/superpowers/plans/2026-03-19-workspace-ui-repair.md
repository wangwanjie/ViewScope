# Workspace UI Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore the workspace split view, finish preview canvas interactions, broaden inspector coverage/editing, and fix hierarchy row rendering without regressing the current fixture or live-host flows.

**Architecture:** Keep split sizing inside the workspace UI layer, add a small preview viewport abstraction so zoom/pan/rotation and hit-testing share one transform model, and drive the inspector from server-provided detail sections instead of the current hardcoded subset. Extend `../ViewScopeServer` only for missing high-value editable properties, then verify the result with focused unit tests, package tests, and macOS UI regression tests.

**Tech Stack:** AppKit, Combine, SnapKit, Swift Testing, XCTest/XCUITest, local Swift package `../ViewScopeServer`

---

### Task 1: Restore the tree/preview divider

**Files:**
- Modify: `ViewScope/UI/Workspace/WorkspaceContentSplitViewController.swift`
- Modify: `ViewScope/UI/Workspace/ViewTreePanelController.swift`
- Modify: `ViewScope/UI/Workspace/PreviewPanelController.swift`
- Create: `ViewScopeUITests/WorkspaceLayoutUITests.swift`

- [ ] **Step 1: Add a failing divider regression test**

Create a UI test that launches the fixture workspace, records the hierarchy panel frame, drags the center divider, and asserts the hierarchy width changes while the preview panel stays visible.

- [ ] **Step 2: Run the new UI test and confirm the failure**

Run: `xcodebuild test -scheme ViewScope -project ViewScope.xcodeproj -destination 'platform=macOS' -only-testing:ViewScopeUITests/WorkspaceLayoutUITests/testTreeDividerResizesPreview`
Expected: FAIL because the divider drag does not change the panel widths or the width snaps back immediately.

- [ ] **Step 3: Add stable panel identifiers for the test seam**

Expose accessibility identifiers on the tree and preview root views so the UI test can measure frames without depending on localized text or fragile view ordering.

- [ ] **Step 4: Fix split layout ownership**

Move the initial divider placement into a reusable layout helper, clamp divider movement against both minimum widths, and enable split-view autosave/persisted sizing so the controller does not overwrite user resizing on later layout passes.

- [ ] **Step 5: Re-run the focused UI test**

Run: `xcodebuild test -scheme ViewScope -project ViewScope.xcodeproj -destination 'platform=macOS' -only-testing:ViewScopeUITests/WorkspaceLayoutUITests/testTreeDividerResizesPreview`
Expected: PASS and the measured tree width differs before and after the drag.

- [ ] **Step 6: Commit**

```bash
git add ViewScope/UI/Workspace/WorkspaceContentSplitViewController.swift ViewScope/UI/Workspace/ViewTreePanelController.swift ViewScope/UI/Workspace/PreviewPanelController.swift ViewScopeUITests/WorkspaceLayoutUITests.swift
git commit -m "fix(workspace): restore tree preview split resizing"
```

### Task 2: Finish preview pan, zoom, rotation, and canvas selection

**Files:**
- Create: `ViewScope/Support/PreviewViewportState.swift`
- Modify: `ViewScope/UI/Workspace/PreviewCanvasView.swift`
- Modify: `ViewScope/UI/Workspace/PreviewPanelController.swift`
- Modify: `ViewScope/Services/WorkspaceStore.swift`
- Create: `ViewScopeTests/PreviewViewportStateTests.swift`
- Create: `ViewScopeUITests/WorkspaceInteractionUITests.swift`

- [ ] **Step 1: Add failing transform and selection tests**

Write unit tests for viewport coordinate conversion after pan/zoom/rotation, plus a UI test that single-clicks the canvas and verifies the selected node title changes in the workspace.

- [ ] **Step 2: Run the focused tests and capture the gaps**

Run: `xcodebuild test -scheme ViewScope -project ViewScope.xcodeproj -destination 'platform=macOS' -only-testing:ViewScopeTests/PreviewViewportStateTests -only-testing:ViewScopeUITests/WorkspaceInteractionUITests/testCanvasClickSelectsNode`
Expected: FAIL because the viewport abstraction does not exist and canvas interaction coverage is incomplete.

- [ ] **Step 3: Add a dedicated viewport model**

Implement `PreviewViewportState` to own scale, content offset, rotation angle, clamping, and inverse point conversion so drawing and hit-testing use the same transform math.

- [ ] **Step 4: Wire gesture handling through the shared transform**

Update `PreviewCanvasView` to handle `scrollWheel(with:)` for two-finger panning, `magnify(with:)` for pinch zoom, `rotate(with:)` for layered-mode rotation, and point conversion for single-click selection plus double-click focus.

- [ ] **Step 5: Keep toolbar actions and programmatic focus in sync**

Add explicit scale-setting APIs in `WorkspaceStore`, feed those values into the viewport model, and make `centerSelectionIfNeeded()` and toolbar zoom/reset actions use the same viewport path instead of bypassing gesture state.

- [ ] **Step 6: Use detail metadata for overlay accuracy**

Prefer `selectedNodeDetail.highlightedRect` when available for the selection overlay and fallback to `ViewHierarchyGeometry` so preview rendering stays aligned across live captures and fixture mode.

- [ ] **Step 7: Re-run the focused tests**

Run: `xcodebuild test -scheme ViewScope -project ViewScope.xcodeproj -destination 'platform=macOS' -only-testing:ViewScopeTests/PreviewViewportStateTests -only-testing:ViewScopeUITests/WorkspaceInteractionUITests/testCanvasClickSelectsNode`
Expected: PASS.

- [ ] **Step 8: Manual gesture verification**

Launch the app with `VIEWSCOPE_PREVIEW_FIXTURE=1` and verify: two-finger drag pans the preview, pinch adjusts zoom smoothly, layered mode rotates only while in 3D view, single-click selects a node, and double-click focuses that subtree.

- [ ] **Step 9: Commit**

```bash
git add ViewScope/Support/PreviewViewportState.swift ViewScope/UI/Workspace/PreviewCanvasView.swift ViewScope/UI/Workspace/PreviewPanelController.swift ViewScope/Services/WorkspaceStore.swift ViewScopeTests/PreviewViewportStateTests.swift ViewScopeUITests/WorkspaceInteractionUITests.swift
git commit -m "feat(workspace): add interactive preview viewport controls"
```

### Task 3: Expand inspector coverage and editable properties

**Files:**
- Modify: `ViewScope/UI/Workspace/InspectorViewModels.swift`
- Modify: `ViewScope/UI/Workspace/InspectorPanelController.swift`
- Modify: `ViewScope/Support/SampleFixture.swift`
- Modify: `../ViewScopeServer/Sources/ViewScopeServer/ViewScopeSnapshotBuilder.swift`
- Modify: `../ViewScopeServer/Sources/ViewScopeServer/ViewScopeInspector.swift`
- Create: `ViewScopeTests/InspectorPanelModelBuilderTests.swift`
- Create: `../ViewScopeServer/Tests/ViewScopeServerTests/ViewScopeMutationSupportTests.swift`

- [ ] **Step 1: Add failing app-side inspector model tests**

Write tests that build inspector models from detail payloads containing `alpha`, `identifier`, `toolTip`, `enabled`, `backgroundColor`, `frame`, `bounds`, and `contentInsets`, then assert the UI model surfaces editable rows when the payload marks them editable and preserves read-only rows otherwise.

- [ ] **Step 2: Add failing server-side mutation tests**

Write package tests proving the server emits editable metadata and applies mutations for the first-pass common property set: `hidden`, `alpha`, `backgroundColor`, `frame.*`, `bounds.*`, `contentInsets.*`, `toolTip`, `identifier`, `enabled`, and `control.value`.

- [ ] **Step 3: Run the focused test suites and confirm the current gaps**

Run: `swift test --package-path ../ViewScopeServer --filter ViewScopeMutationSupportTests`
Expected: FAIL because several properties are not emitted as editable or cannot yet be mutated.

Run: `xcodebuild test -scheme ViewScope -project ViewScope.xcodeproj -destination 'platform=macOS' -only-testing:ViewScopeTests/InspectorPanelModelBuilderTests`
Expected: FAIL because the current builder hardcodes only a narrow subset of rows.

- [ ] **Step 4: Refactor the inspector model builder**

Change `InspectorPanelModelBuilder` to derive sections from the server payload, keep compact quad rows for grouped geometry fields, map editable payload items to the correct row type automatically, and retain any unknown server items as read-only rows instead of dropping them.

- [ ] **Step 5: Extend server metadata and mutation handling**

Teach `ViewScopeSnapshotBuilder` to emit editable metadata for the missing common properties and extend `ViewScopeInspector` mutation routing with type-specific validation plus AppKit-safe application for view/control-specific properties.

- [ ] **Step 6: Refresh the fixture data**

Update `SampleFixture.detail(for:)` so preview mode exercises the broader inspector coverage and the new editable keys without requiring a live host.

- [ ] **Step 7: Re-run the focused app and package tests**

Run: `swift test --package-path ../ViewScopeServer --filter ViewScopeMutationSupportTests`
Expected: PASS.

Run: `xcodebuild test -scheme ViewScope -project ViewScope.xcodeproj -destination 'platform=macOS' -only-testing:ViewScopeTests/InspectorPanelModelBuilderTests`
Expected: PASS.

- [ ] **Step 8: Manual mutation verification**

Connect to a fixture or live host and verify that editing common text/number/toggle/color rows updates the target view, refreshes the capture, and rolls back the edited row when the mutation is rejected.

- [ ] **Step 9: Commit**

```bash
git add ViewScope/UI/Workspace/InspectorViewModels.swift ViewScope/UI/Workspace/InspectorPanelController.swift ViewScope/Support/SampleFixture.swift ../ViewScopeServer/Sources/ViewScopeServer/ViewScopeSnapshotBuilder.swift ../ViewScopeServer/Sources/ViewScopeServer/ViewScopeInspector.swift ViewScopeTests/InspectorPanelModelBuilderTests.swift ../ViewScopeServer/Tests/ViewScopeServerTests/ViewScopeMutationSupportTests.swift
git commit -m "feat(inspector): surface and edit richer node properties"
```

### Task 4: Fix hierarchy outline row sizing and overlap

**Files:**
- Modify: `ViewScope/UI/Workspace/ViewTreePanelController.swift`
- Create: `ViewScopeTests/ViewTreeNodeCellLayoutTests.swift`
- Modify: `ViewScopeUITests/WorkspaceLayoutUITests.swift`

- [ ] **Step 1: Add a failing row layout test**

Add a focused test that instantiates the tree cell view, forces layout, and asserts the title/subtitle stack plus visibility button fit within the row bounds without negative spacing or clipped overlap.

- [ ] **Step 2: Add a failing UI regression for the outline**

Extend the workspace layout UI test to launch the fixture tree, expand a few nodes, and assert adjacent outline rows do not overlap after scrolling.

- [ ] **Step 3: Run the focused tests and confirm the visual regression**

Run: `xcodebuild test -scheme ViewScope -project ViewScope.xcodeproj -destination 'platform=macOS' -only-testing:ViewScopeTests/ViewTreeNodeCellLayoutTests -only-testing:ViewScopeUITests/WorkspaceLayoutUITests/testHierarchyRowsDoNotOverlap`
Expected: FAIL because the current cell layout is too tight for the stacked labels and button.

- [ ] **Step 4: Fix the cell layout contract**

Pin the labels stack to the cell top and bottom insets, tune row/intercell spacing, and either raise the fixed row height or implement `outlineView(_:heightOfRowByItem:)` so row geometry matches the rendered content.

- [ ] **Step 5: Re-run the focused tests**

Run: `xcodebuild test -scheme ViewScope -project ViewScope.xcodeproj -destination 'platform=macOS' -only-testing:ViewScopeTests/ViewTreeNodeCellLayoutTests -only-testing:ViewScopeUITests/WorkspaceLayoutUITests/testHierarchyRowsDoNotOverlap`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add ViewScope/UI/Workspace/ViewTreePanelController.swift ViewScopeTests/ViewTreeNodeCellLayoutTests.swift ViewScopeUITests/WorkspaceLayoutUITests.swift
git commit -m "fix(hierarchy): correct outline row sizing"
```

### Task 5: Run full verification and polish regressions

**Files:**
- Verify: `ViewScopeTests`
- Verify: `ViewScopeUITests`
- Verify: `../ViewScopeServer/Tests/ViewScopeServerTests`

- [ ] **Step 1: Run the full server package test suite**

Run: `swift test --package-path ../ViewScopeServer`
Expected: PASS with all `ViewScopeServerTests` green.

- [ ] **Step 2: Run the full macOS app test suite**

Run: `xcodebuild test -scheme ViewScope -project ViewScope.xcodeproj -destination 'platform=macOS'`
Expected: PASS with `ViewScopeTests` and `ViewScopeUITests` green.

- [ ] **Step 3: Perform end-to-end manual QA**

Verify the divider keeps its resized width, preview gestures behave naturally on a trackpad, canvas clicks select the expected node, inspector edits update the host, and hierarchy rows remain readable after search, selection, expansion, and scrolling.

- [ ] **Step 4: Capture any last-mile fixes discovered during QA**

Apply only the smallest regression fixes needed to make the above checks pass; avoid unrelated refactors.

- [ ] **Step 5: Re-run the exact failing suite from Step 4 if any regression was fixed**

Run only the targeted test command for the touched area, then repeat the full suite if a shared preview or inspector file changed.

- [ ] **Step 6: Commit**

```bash
git add ViewScope ViewScopeTests ViewScopeUITests ../ViewScopeServer
git commit -m "test(workspace): verify workspace ui repair plan"
```
