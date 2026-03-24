# Architecture Responsibility Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reorganize `ViewScope` and `ViewScopeServer` by function, split overloaded files into focused collaborators, remove duplicated logic, and add Chinese comments only where the logic is genuinely hard to understand.

**Architecture:** Keep stable entry points and externally observable behavior, but move implementation behind functional boundaries. Extract client workspace state into connection/capture/selection/preview/console collaborators first, then split inspector/tree/preview UI composition, and finally break the server into public API, runtime routing, snapshot building, mutation execution, and support helpers.

**Tech Stack:** Swift, AppKit, Combine, SnapKit, SceneKit, XCTest/Testing, Swift Package Manager, Xcode project files

---

## File Structure

- Modify: `ViewScope/ViewScope.xcodeproj/project.pbxproj`
  Purpose: Register newly created client source files and tests after the split.
- Modify: `ViewScopeServer/ViewScopeServer.xcodeproj/project.pbxproj`
  Purpose: Register newly created server source files if the Xcode project still builds the framework target directly.
- Modify: `Package.swift`
  Purpose: Keep root package exports aligned if any source path assumptions change.
- Modify: `ViewScope/ViewScope/ApplicationMain.swift`
  Purpose: Point the app bootstrap at the reorganized application/workspace entry types if names move.
- Modify: `ViewScope/ViewScope/AppDelegate.swift`
  Purpose: Keep app startup and top-level wiring compatible with the new module layout.
- Modify: `ViewScope/ViewScope/Services/WorkspaceStore.swift`
  Purpose: Reduce it to a thin workspace facade that delegates to focused collaborators.
- Create: `ViewScope/ViewScope/Workspace/Core/WorkspaceStore.swift`
  Purpose: Host the slimmed facade if the original path is retired.
- Create: `ViewScope/ViewScope/Workspace/Connection/WorkspaceConnectionCoordinator.swift`
  Purpose: Own discovery binding, connection generations, and active-session lifecycle.
- Create: `ViewScope/ViewScope/Workspace/Capture/WorkspaceCaptureCoordinator.swift`
  Purpose: Own capture refresh, import/export, and post-refresh state normalization.
- Create: `ViewScope/ViewScope/Workspace/Core/WorkspaceSelectionController.swift`
  Purpose: Own selected/focused/expanded node state and visibility fallback rules.
- Create: `ViewScope/ViewScope/Workspace/Preview/WorkspacePreviewState.swift`
  Purpose: Own preview settings, zoom, display mode, and persisted preview preferences.
- Create: `ViewScope/ViewScope/Workspace/Console/WorkspaceConsoleController.swift`
  Purpose: Own console targets, history rows, auto-sync, and submission lifecycle.
- Modify: `ViewScope/ViewScope/Services/WorkspaceSessionProtocol.swift`
  Purpose: Keep the session surface coherent after moving workspace coordination code.
- Modify: `ViewScope/ViewScope/Services/ViewScopeClientSession.swift`
  Purpose: Reuse extracted request helpers and keep transport responsibilities isolated.
- Modify: `ViewScope/ViewScope/Services/AppSettings.swift`
  Purpose: Continue exposing persisted settings from the new feature-focused modules.
- Modify: `ViewScope/ViewScope/UI/Workspace/InspectorPanelController.swift`
  Purpose: Reduce it to section assembly and store binding.
- Create: `ViewScope/ViewScope/Workspace/Inspector/InspectorPropertyCommitCoordinator.swift`
  Purpose: Centralize inspector value parsing, validation, mutation submission, and rollback.
- Create: `ViewScope/ViewScope/Workspace/Inspector/InspectorSectionCardView.swift`
  Purpose: Move inspector card styling out of the controller file.
- Create: `ViewScope/ViewScope/Workspace/Inspector/Rows/InspectorCommitCapable.swift`
  Purpose: Share the editing/reset contract across editable inspector rows.
- Create: `ViewScope/ViewScope/Workspace/Inspector/Rows/InspectorReadOnlyRowView.swift`
  Purpose: Host read-only inspector row UI.
- Create: `ViewScope/ViewScope/Workspace/Inspector/Rows/InspectorListRowView.swift`
  Purpose: Host list inspector row UI.
- Create: `ViewScope/ViewScope/Workspace/Inspector/Rows/InspectorEditableTextRowView.swift`
  Purpose: Host text inspector row UI.
- Create: `ViewScope/ViewScope/Workspace/Inspector/Rows/InspectorEditableNumberRowView.swift`
  Purpose: Host number inspector row UI.
- Create: `ViewScope/ViewScope/Workspace/Inspector/Rows/InspectorEditableToggleRowView.swift`
  Purpose: Host toggle inspector row UI.
- Create: `ViewScope/ViewScope/Workspace/Inspector/Rows/InspectorEditableQuadRowView.swift`
  Purpose: Host quad-number inspector row UI.
- Create: `ViewScope/ViewScope/Workspace/Inspector/Rows/InspectorEditableColorRowView.swift`
  Purpose: Host color inspector row UI.
- Modify: `ViewScope/ViewScope/UI/Workspace/ViewTreePanelController.swift`
  Purpose: Keep only outline-view orchestration and user interactions.
- Create: `ViewScope/ViewScope/Workspace/Hierarchy/ViewTreePresentationBuilder.swift`
  Purpose: Build filtered/searchable tree presentation models.
- Create: `ViewScope/ViewScope/Workspace/Hierarchy/ViewTreeSelectionSynchronizer.swift`
  Purpose: Isolate programmatic selection/expansion synchronization.
- Modify: `ViewScope/ViewScope/UI/Workspace/PreviewPanelController.swift`
  Purpose: Keep only preview-shell layout and tool dispatch.
- Modify: `ViewScope/ViewScope/UI/Workspace/PreviewLayeredSceneView.swift`
  Purpose: Reduce it to scene host responsibilities.
- Create: `ViewScope/ViewScope/Workspace/Preview/PreviewRenderContextBuilder.swift`
  Purpose: Derive a stable render context from capture/detail/selection/settings.
- Create: `ViewScope/ViewScope/Workspace/Preview/PreviewToolbarState.swift`
  Purpose: Compute preview-toolbar availability and labels.
- Create: `ViewScope/ViewScope/Workspace/Preview/Scene/PreviewLayeredSceneRenderer.swift`
  Purpose: Handle structural-state comparison, node creation, and scene refresh.
- Create: `ViewScope/ViewScope/Workspace/Preview/Scene/PreviewLayeredSceneInteractionController.swift`
  Purpose: Handle drag/rotate/zoom interaction state separately from rendering.
- Modify: `ViewScope/ViewScope/UI/Workspace/ConsolePanelController.swift`
  Purpose: Use the extracted console controller/model helpers instead of embedding all behavior locally.
- Modify: `ViewScope/ViewScope/UI/Workspace/ConsoleViewModels.swift`
  Purpose: Remove duplicated target-row derivation after console responsibilities move.
- Modify: `ViewScope/ViewScope/Support/PreviewLayeredRenderPlan.swift`
  Purpose: Add clarifying Chinese comments if any plan logic remains complex after preview refactor.
- Modify: `ViewScope/ViewScope/Support/PreviewViewportState.swift`
  Purpose: Keep viewport math aligned with the new preview render context if needed.
- Modify: `ViewScope/ViewScope/Support/SampleFixture.swift`
  Purpose: Keep fixture data aligned with the reorganized workspace state flow.
- Modify: `ViewScope/ViewScopeTests/WorkspaceStoreConnectionLifecycleTests.swift`
  Purpose: Lock down connection-generation and host-switch behavior during the split.
- Modify: `ViewScope/ViewScopeTests/WorkspaceImportTests.swift`
  Purpose: Lock down import/export behavior after capture code moves.
- Modify: `ViewScope/ViewScopeTests/InspectorPanelModelBuilderTests.swift`
  Purpose: Extend inspector tests with commit/rollback cases after extraction.
- Create: `ViewScope/ViewScopeTests/InspectorPropertyCommitCoordinatorTests.swift`
  Purpose: Cover parsing, rollback, and mutation dispatch without going through the full controller.
- Create: `ViewScope/ViewScopeTests/ViewTreePresentationBuilderTests.swift`
  Purpose: Cover wrapper filtering, search matches, and root derivation.
- Create: `ViewScope/ViewScopeTests/PreviewRenderContextBuilderTests.swift`
  Purpose: Cover image resolution, geometry mode selection, and context fallback rules.
- Modify: `ViewScope/ViewScopeTests/PreviewLayeredScenePlanTests.swift`
  Purpose: Keep layered-scene structural behavior stable while scene rendering code moves.
- Modify: `ViewScope/ViewScopeTests/ViewScopeTests.swift`
  Purpose: Keep high-level fixture and smoke coverage current with moved files.
- Modify: `ViewScopeServer/Sources/ViewScopeServer/ViewScopeInspector.swift`
  Purpose: Reduce it to the public entry facade and thin runtime bootstrap if the file remains.
- Modify: `ViewScopeServer/Sources/ViewScopeServer/ViewScopeSnapshotBuilder.swift`
  Purpose: Retire or drastically slim it after extracting snapshot collaborators.
- Modify: `ViewScopeServer/Sources/ViewScopeServer/ViewScopeBridge.swift`
  Purpose: Split public bridge types by responsibility.
- Create: `ViewScopeServer/Sources/ViewScopeServer/PublicAPI/ViewScopeInspector.swift`
  Purpose: Keep the stable server entry point under a dedicated public API directory.
- Create: `ViewScopeServer/Sources/ViewScopeServer/Bootstrap/ViewScopeInspectorLifecycle.swift`
  Purpose: Own automatic-start enable/disable and reset behavior.
- Create: `ViewScopeServer/Sources/ViewScopeServer/Inspection/InspectorRuntime.swift`
  Purpose: Own listener startup, active connection state, and runtime-scoped collaborators.
- Create: `ViewScopeServer/Sources/ViewScopeServer/Discovery/InspectorDiscoveryPublisher.swift`
  Purpose: Own discovery announcement, request rebroadcast, and termination posting.
- Create: `ViewScopeServer/Sources/ViewScopeServer/Inspection/InspectorRequestRouter.swift`
  Purpose: Route incoming messages to capture/detail/highlight/mutation/console handlers.
- Create: `ViewScopeServer/Sources/ViewScopeServer/Mutation/ViewMutationExecutor.swift`
  Purpose: Centralize editable-property routing and AppKit mutation safety rules.
- Create: `ViewScopeServer/Sources/ViewScopeServer/Snapshot/SnapshotCaptureBuilder.swift`
  Purpose: Own top-level capture creation and summary generation.
- Create: `ViewScopeServer/Sources/ViewScopeServer/Snapshot/SnapshotTreeBuilder.swift`
  Purpose: Own node-tree construction and reference-context assembly.
- Create: `ViewScopeServer/Sources/ViewScopeServer/Snapshot/SnapshotChildViewCollector.swift`
  Purpose: Own direct-child collection rules for AppKit containers.
- Create: `ViewScopeServer/Sources/ViewScopeServer/Snapshot/SnapshotIvarTraceBuilder.swift`
  Purpose: Own direct-subview ivar trace lookup.
- Create: `ViewScopeServer/Sources/ViewScopeServer/Snapshot/SnapshotDetailBuilder.swift`
  Purpose: Own detail payload generation.
- Create: `ViewScopeServer/Sources/ViewScopeServer/Snapshot/SnapshotScreenshotRenderer.swift`
  Purpose: Own screenshot generation and composite-capture policy.
- Create: `ViewScopeServer/Sources/ViewScopeServer/Console/SnapshotConsoleTargetBuilder.swift`
  Purpose: Own console target descriptors sourced from live references.
- Create: `ViewScopeServer/Sources/ViewScopeServer/Support/ViewScopeRuntimeIvarReader.swift`
  Purpose: Move Objective-C ivar helpers out of snapshot builder.
- Create: `ViewScopeServer/Sources/ViewScopeServer/PublicAPI/ViewScopeBridge+Discovery.swift`
  Purpose: Hold announcement and host-info bridge types.
- Create: `ViewScopeServer/Sources/ViewScopeServer/PublicAPI/ViewScopeBridge+Geometry.swift`
  Purpose: Hold rect/size bridge types.
- Create: `ViewScopeServer/Sources/ViewScopeServer/PublicAPI/ViewScopeBridge+Hierarchy.swift`
  Purpose: Hold hierarchy-node and related metadata bridge types.
- Create: `ViewScopeServer/Sources/ViewScopeServer/PublicAPI/ViewScopeBridge+Capture.swift`
  Purpose: Hold capture/detail payload types.
- Create: `ViewScopeServer/Sources/ViewScopeServer/PublicAPI/ViewScopeBridge+Console.swift`
  Purpose: Hold console bridge types.
- Create: `ViewScopeServer/Sources/ViewScopeServer/PublicAPI/ViewScopeBridge+Mutation.swift`
  Purpose: Hold editable-property and mutation message payloads.
- Modify: `ViewScopeServer/Tests/ViewScopeServerTests/ViewScopeServerTests.swift`
  Purpose: Preserve end-to-end server behavior coverage during file extraction.
- Create: `ViewScopeServer/Tests/ViewScopeServerTests/ViewMutationExecutorTests.swift`
  Purpose: Cover per-property mutation routing and invalid-value failures.
- Create: `ViewScopeServer/Tests/ViewScopeServerTests/SnapshotTreeBuilderTests.swift`
  Purpose: Cover node-tree, child-collector, and ivar-trace rules independently.
- Create: `ViewScopeServer/Tests/ViewScopeServerTests/SnapshotDetailBuilderTests.swift`
  Purpose: Cover detail sections, screenshot roots, and console target derivation.

## Task 1: Establish Functional Module Boundaries Without Changing Behavior

**Files:**
- Modify: `ViewScope/ViewScope.xcodeproj/project.pbxproj`
- Modify: `ViewScopeServer/ViewScopeServer.xcodeproj/project.pbxproj`
- Modify: `Package.swift`
- Create: target directories under `ViewScope/ViewScope/Workspace/` and `ViewScopeServer/Sources/ViewScopeServer/`

- [ ] **Step 1: Write the failing structure smoke checks**

Add or extend a lightweight test that references the new type names so the build proves the module split is wired correctly:

```swift
@testable import ViewScope

final class WorkspaceModuleSmokeTests: XCTestCase {
    func testModulesAreVisible() {
        _ = WorkspaceSelectionController.self
        _ = PreviewRenderContextBuilder.self
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project ViewScope/ViewScope.xcodeproj -scheme ViewScope -destination 'platform=macOS' test -only-testing:ViewScopeTests/WorkspaceModuleSmokeTests`
Expected: FAIL with missing extracted types or missing project references.

- [ ] **Step 3: Create the target folders and add placeholder shells**

Create minimal compilable files such as:

```swift
@MainActor
final class WorkspaceSelectionController {}

struct PreviewRenderContextBuilder {}
```

Also add the new files to the Xcode project and keep package paths valid.

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project ViewScope/ViewScope.xcodeproj -scheme ViewScope -destination 'platform=macOS' test -only-testing:ViewScopeTests/WorkspaceModuleSmokeTests`
Expected: PASS and the app target resolves the new files.

- [ ] **Step 5: Commit**

```bash
git add ViewScope/ViewScope.xcodeproj/project.pbxproj ViewScopeServer/ViewScopeServer.xcodeproj/project.pbxproj Package.swift ViewScope/ViewScope/Workspace ViewScopeServer/Sources/ViewScopeServer
git commit -m "refactor: establish functional module boundaries"
```

## Task 2: Split Workspace State Into Coordinators

**Files:**
- Modify: `ViewScope/ViewScope/Services/WorkspaceStore.swift`
- Create: `ViewScope/ViewScope/Workspace/Connection/WorkspaceConnectionCoordinator.swift`
- Create: `ViewScope/ViewScope/Workspace/Capture/WorkspaceCaptureCoordinator.swift`
- Create: `ViewScope/ViewScope/Workspace/Core/WorkspaceSelectionController.swift`
- Create: `ViewScope/ViewScope/Workspace/Preview/WorkspacePreviewState.swift`
- Create: `ViewScope/ViewScope/Workspace/Console/WorkspaceConsoleController.swift`
- Modify: `ViewScope/ViewScope/Services/WorkspaceSessionProtocol.swift`
- Modify: `ViewScope/ViewScope/Services/ViewScopeClientSession.swift`
- Test: `ViewScope/ViewScopeTests/WorkspaceStoreConnectionLifecycleTests.swift`
- Test: `ViewScope/ViewScopeTests/WorkspaceImportTests.swift`

- [ ] **Step 1: Write the failing workspace-coordinator tests**

Add focused tests for:

```swift
func testDisconnectClearsConnectionOwnedStateButKeepsSettingsBackedPreviewDefaults() async throws
func testRefreshCaptureRebuildsSelectionAndConsoleStateThroughCoordinator() async throws
func testImportExportUsesCaptureCoordinatorWithoutNeedingLiveSession() throws
```

Assert that selection, console rows, and preview state end in the same values as before extraction.

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project ViewScope/ViewScope.xcodeproj -scheme ViewScope -destination 'platform=macOS' test -only-testing:ViewScopeTests/WorkspaceStoreConnectionLifecycleTests -only-testing:ViewScopeTests/WorkspaceImportTests`
Expected: FAIL because the coordinator types do not yet own the tested behavior.

- [ ] **Step 3: Move logic into focused collaborators**

Extract logic behind interfaces similar to:

```swift
@MainActor
final class WorkspaceConnectionCoordinator {
    func connect(to host: ViewScopeHostAnnouncement) async throws -> WorkspaceConnectionResult { ... }
    func disconnectCurrentSession() { ... }
}

@MainActor
final class WorkspaceCaptureCoordinator {
    func refresh(using session: (any WorkspaceSessionProtocol)?, preferredNodeID: String?) async throws -> WorkspaceCaptureRefreshResult { ... }
}
```

`WorkspaceStore` should become a thin facade that publishes state and delegates commands.

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project ViewScope/ViewScope.xcodeproj -scheme ViewScope -destination 'platform=macOS' test -only-testing:ViewScopeTests/WorkspaceStoreConnectionLifecycleTests -only-testing:ViewScopeTests/WorkspaceImportTests`
Expected: PASS with unchanged host-switch and import/export behavior.

- [ ] **Step 5: Commit**

```bash
git add ViewScope/ViewScope/Services/WorkspaceStore.swift ViewScope/ViewScope/Services/WorkspaceSessionProtocol.swift ViewScope/ViewScope/Services/ViewScopeClientSession.swift ViewScope/ViewScope/Workspace/Connection/WorkspaceConnectionCoordinator.swift ViewScope/ViewScope/Workspace/Capture/WorkspaceCaptureCoordinator.swift ViewScope/ViewScope/Workspace/Core/WorkspaceSelectionController.swift ViewScope/ViewScope/Workspace/Preview/WorkspacePreviewState.swift ViewScope/ViewScope/Workspace/Console/WorkspaceConsoleController.swift ViewScope/ViewScopeTests/WorkspaceStoreConnectionLifecycleTests.swift ViewScope/ViewScopeTests/WorkspaceImportTests.swift
git commit -m "refactor: split workspace state coordinators"
```

## Task 3: Extract Inspector Commit Flow And Row Views

**Files:**
- Modify: `ViewScope/ViewScope/UI/Workspace/InspectorPanelController.swift`
- Create: `ViewScope/ViewScope/Workspace/Inspector/InspectorPropertyCommitCoordinator.swift`
- Create: `ViewScope/ViewScope/Workspace/Inspector/InspectorSectionCardView.swift`
- Create: `ViewScope/ViewScope/Workspace/Inspector/Rows/InspectorCommitCapable.swift`
- Create: `ViewScope/ViewScope/Workspace/Inspector/Rows/InspectorReadOnlyRowView.swift`
- Create: `ViewScope/ViewScope/Workspace/Inspector/Rows/InspectorListRowView.swift`
- Create: `ViewScope/ViewScope/Workspace/Inspector/Rows/InspectorEditableTextRowView.swift`
- Create: `ViewScope/ViewScope/Workspace/Inspector/Rows/InspectorEditableNumberRowView.swift`
- Create: `ViewScope/ViewScope/Workspace/Inspector/Rows/InspectorEditableToggleRowView.swift`
- Create: `ViewScope/ViewScope/Workspace/Inspector/Rows/InspectorEditableQuadRowView.swift`
- Create: `ViewScope/ViewScope/Workspace/Inspector/Rows/InspectorEditableColorRowView.swift`
- Create: `ViewScope/ViewScopeTests/InspectorPropertyCommitCoordinatorTests.swift`
- Modify: `ViewScope/ViewScopeTests/InspectorPanelModelBuilderTests.swift`

- [ ] **Step 1: Write the failing inspector commit tests**

Add tests that lock down parsing and rollback rules:

```swift
func testNumberCommitRejectsInvalidLocalizedInputAndRequestsReset()
func testColorCommitUppercasesHexBeforeMutation()
func testFailedMutationReenablesEditingAndRestoresOriginalValue() async
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project ViewScope/ViewScope.xcodeproj -scheme ViewScope -destination 'platform=macOS' test -only-testing:ViewScopeTests/InspectorPropertyCommitCoordinatorTests`
Expected: FAIL because the commit coordinator does not exist yet.

- [ ] **Step 3: Extract the coordinator and move row classes out of the controller**

Implement a shared commit coordinator:

```swift
@MainActor
final class InspectorPropertyCommitCoordinator {
    func commitNumber(_ value: String, property: ViewScopeEditableProperty, rowView: InspectorCommitCapable, nodeID: String) { ... }
    func commitColor(_ value: String, property: ViewScopeEditableProperty, rowView: InspectorCommitCapable, nodeID: String) { ... }
}
```

Leave `InspectorPanelController` responsible only for building section views and binding closures.

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project ViewScope/ViewScope.xcodeproj -scheme ViewScope -destination 'platform=macOS' test -only-testing:ViewScopeTests/InspectorPropertyCommitCoordinatorTests -only-testing:ViewScopeTests/InspectorPanelModelBuilderTests`
Expected: PASS and `InspectorPanelController.swift` shrinks to orchestration only.

- [ ] **Step 5: Commit**

```bash
git add ViewScope/ViewScope/UI/Workspace/InspectorPanelController.swift ViewScope/ViewScope/Workspace/Inspector ViewScope/ViewScopeTests/InspectorPropertyCommitCoordinatorTests.swift ViewScope/ViewScopeTests/InspectorPanelModelBuilderTests.swift
git commit -m "refactor: extract inspector commit flow"
```

## Task 4: Extract Hierarchy Presentation And Selection Synchronization

**Files:**
- Modify: `ViewScope/ViewScope/UI/Workspace/ViewTreePanelController.swift`
- Create: `ViewScope/ViewScope/Workspace/Hierarchy/ViewTreePresentationBuilder.swift`
- Create: `ViewScope/ViewScope/Workspace/Hierarchy/ViewTreeSelectionSynchronizer.swift`
- Create: `ViewScope/ViewScopeTests/ViewTreePresentationBuilderTests.swift`
- Modify: `ViewScope/ViewScopeTests/ViewScopeTests.swift`

- [ ] **Step 1: Write the failing hierarchy tests**

Add tests for:

```swift
func testPresentationBuilderFiltersSystemWrappersWithoutChangingUnderlyingRoots()
func testSearchMatchesControllerSuffixIdentifiersAndEventMetadata()
func testSelectionSynchronizerSkipsReentrantProgrammaticSelection()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project ViewScope/ViewScope.xcodeproj -scheme ViewScope -destination 'platform=macOS' test -only-testing:ViewScopeTests/ViewTreePresentationBuilderTests`
Expected: FAIL because the extracted builder/synchronizer types are missing.

- [ ] **Step 3: Move filtering/search/selection logic out of the controller**

Extract APIs similar to:

```swift
struct ViewTreePresentationBuilder {
    func buildRoots(from capture: ViewScopeCapturePayload, focusedNodeID: String?, showsSystemWrappers: Bool, query: String) -> [ViewTreeNodeItem] { ... }
}

@MainActor
final class ViewTreeSelectionSynchronizer {
    func syncSelection(from store: WorkspaceStore, into outlineView: NSOutlineView, rootItems: [ViewTreeNodeItem]) { ... }
}
```

Keep Chinese comments near wrapper-filter heuristics and visibility fallback rules if those remain non-obvious.

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project ViewScope/ViewScope.xcodeproj -scheme ViewScope -destination 'platform=macOS' test -only-testing:ViewScopeTests/ViewTreePresentationBuilderTests -only-testing:ViewScopeTests/ViewScopeTests`
Expected: PASS with unchanged hierarchy behavior.

- [ ] **Step 5: Commit**

```bash
git add ViewScope/ViewScope/UI/Workspace/ViewTreePanelController.swift ViewScope/ViewScope/Workspace/Hierarchy/ViewTreePresentationBuilder.swift ViewScope/ViewScope/Workspace/Hierarchy/ViewTreeSelectionSynchronizer.swift ViewScope/ViewScopeTests/ViewTreePresentationBuilderTests.swift ViewScope/ViewScopeTests/ViewScopeTests.swift
git commit -m "refactor: extract hierarchy presentation logic"
```

## Task 5: Split Preview Context, Toolbar State, And Scene Rendering

**Files:**
- Modify: `ViewScope/ViewScope/UI/Workspace/PreviewPanelController.swift`
- Modify: `ViewScope/ViewScope/UI/Workspace/PreviewLayeredSceneView.swift`
- Create: `ViewScope/ViewScope/Workspace/Preview/PreviewRenderContextBuilder.swift`
- Create: `ViewScope/ViewScope/Workspace/Preview/PreviewToolbarState.swift`
- Create: `ViewScope/ViewScope/Workspace/Preview/Scene/PreviewLayeredSceneRenderer.swift`
- Create: `ViewScope/ViewScope/Workspace/Preview/Scene/PreviewLayeredSceneInteractionController.swift`
- Create: `ViewScope/ViewScopeTests/PreviewRenderContextBuilderTests.swift`
- Modify: `ViewScope/ViewScopeTests/PreviewLayeredScenePlanTests.swift`

- [ ] **Step 1: Write the failing preview tests**

Add tests for:

```swift
func testRenderContextPrefersCaptureBitmapThenFallsBackToDetailScreenshot()
func testToolbarStateReflectsFocusVisibilityAndConsoleAvailability()
func testLayeredSceneRendererReusesStructuralStateWhenOnlySelectionChanges()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project ViewScope/ViewScope.xcodeproj -scheme ViewScope -destination 'platform=macOS' test -only-testing:ViewScopeTests/PreviewRenderContextBuilderTests -only-testing:ViewScopeTests/PreviewLayeredScenePlanTests`
Expected: FAIL because the extracted preview helpers do not exist yet.

- [ ] **Step 3: Extract render-context and scene-specific responsibilities**

Implement focused helpers such as:

```swift
struct PreviewRenderContextBuilder {
    func makeContext(store: WorkspaceStore, geometry: ViewHierarchyGeometry) -> PreviewRenderContext { ... }
}

@MainActor
final class PreviewLayeredSceneRenderer {
    func refreshScene(in view: PreviewLayeredSceneView, context: PreviewRenderContext) { ... }
}
```

Move Chinese comments to the geometry-mode selection, image fallback path, and scene structural-state rules.

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project ViewScope/ViewScope.xcodeproj -scheme ViewScope -destination 'platform=macOS' test -only-testing:ViewScopeTests/PreviewRenderContextBuilderTests -only-testing:ViewScopeTests/PreviewLayeredScenePlanTests`
Expected: PASS and the preview controllers become thinner without behavior drift.

- [ ] **Step 5: Commit**

```bash
git add ViewScope/ViewScope/UI/Workspace/PreviewPanelController.swift ViewScope/ViewScope/UI/Workspace/PreviewLayeredSceneView.swift ViewScope/ViewScope/Workspace/Preview/PreviewRenderContextBuilder.swift ViewScope/ViewScope/Workspace/Preview/PreviewToolbarState.swift ViewScope/ViewScope/Workspace/Preview/Scene/PreviewLayeredSceneRenderer.swift ViewScope/ViewScope/Workspace/Preview/Scene/PreviewLayeredSceneInteractionController.swift ViewScope/ViewScopeTests/PreviewRenderContextBuilderTests.swift ViewScope/ViewScopeTests/PreviewLayeredScenePlanTests.swift
git commit -m "refactor: split preview rendering responsibilities"
```

## Task 6: Split Server Public API, Runtime Lifecycle, And Request Routing

**Files:**
- Modify: `ViewScopeServer/Sources/ViewScopeServer/ViewScopeInspector.swift`
- Modify: `ViewScopeServer/Sources/ViewScopeServer/ViewScopeBridge.swift`
- Create: `ViewScopeServer/Sources/ViewScopeServer/PublicAPI/ViewScopeInspector.swift`
- Create: `ViewScopeServer/Sources/ViewScopeServer/Bootstrap/ViewScopeInspectorLifecycle.swift`
- Create: `ViewScopeServer/Sources/ViewScopeServer/Inspection/InspectorRuntime.swift`
- Create: `ViewScopeServer/Sources/ViewScopeServer/Discovery/InspectorDiscoveryPublisher.swift`
- Create: `ViewScopeServer/Sources/ViewScopeServer/Inspection/InspectorRequestRouter.swift`
- Create: `ViewScopeServer/Sources/ViewScopeServer/PublicAPI/ViewScopeBridge+Discovery.swift`
- Create: `ViewScopeServer/Sources/ViewScopeServer/PublicAPI/ViewScopeBridge+Geometry.swift`
- Create: `ViewScopeServer/Sources/ViewScopeServer/PublicAPI/ViewScopeBridge+Hierarchy.swift`
- Create: `ViewScopeServer/Sources/ViewScopeServer/PublicAPI/ViewScopeBridge+Capture.swift`
- Create: `ViewScopeServer/Sources/ViewScopeServer/PublicAPI/ViewScopeBridge+Console.swift`
- Create: `ViewScopeServer/Sources/ViewScopeServer/PublicAPI/ViewScopeBridge+Mutation.swift`
- Test: `ViewScopeServer/Tests/ViewScopeServerTests/ViewScopeServerTests.swift`

- [ ] **Step 1: Write the failing server-runtime tests**

Add tests for:

```swift
func testAutomaticStartLifecycleStillCallsConfiguredStartHandlerOnce() async
func testRuntimePublishesTerminationWhenStopped()
func testRequestRouterKeepsCaptureAndMutationBranchesReachable()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path ViewScopeServer --filter ViewScopeServerTests`
Expected: FAIL because the extracted runtime and bridge-split files do not exist yet.

- [ ] **Step 3: Split the public API and runtime collaborators**

Keep the stable public entry:

```swift
public enum ViewScopeInspector {
    @MainActor public static func start(configuration: Configuration = .init()) { ... }
}
```

Move implementation details behind `InspectorRuntime` and `InspectorRequestRouter`, and split bridge types into themed files without changing serialization semantics.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path ViewScopeServer --filter ViewScopeServerTests`
Expected: PASS with the same public `ViewScopeInspector` behavior.

- [ ] **Step 5: Commit**

```bash
git add ViewScopeServer/Sources/ViewScopeServer/ViewScopeInspector.swift ViewScopeServer/Sources/ViewScopeServer/ViewScopeBridge.swift ViewScopeServer/Sources/ViewScopeServer/PublicAPI ViewScopeServer/Sources/ViewScopeServer/Bootstrap/ViewScopeInspectorLifecycle.swift ViewScopeServer/Sources/ViewScopeServer/Inspection/InspectorRuntime.swift ViewScopeServer/Sources/ViewScopeServer/Inspection/InspectorRequestRouter.swift ViewScopeServer/Sources/ViewScopeServer/Discovery/InspectorDiscoveryPublisher.swift ViewScopeServer/Tests/ViewScopeServerTests/ViewScopeServerTests.swift
git commit -m "refactor: split server runtime and bridge types"
```

## Task 7: Split Snapshot Pipeline And Mutation Execution

**Files:**
- Modify: `ViewScopeServer/Sources/ViewScopeServer/ViewScopeSnapshotBuilder.swift`
- Create: `ViewScopeServer/Sources/ViewScopeServer/Snapshot/SnapshotCaptureBuilder.swift`
- Create: `ViewScopeServer/Sources/ViewScopeServer/Snapshot/SnapshotTreeBuilder.swift`
- Create: `ViewScopeServer/Sources/ViewScopeServer/Snapshot/SnapshotChildViewCollector.swift`
- Create: `ViewScopeServer/Sources/ViewScopeServer/Snapshot/SnapshotIvarTraceBuilder.swift`
- Create: `ViewScopeServer/Sources/ViewScopeServer/Snapshot/SnapshotDetailBuilder.swift`
- Create: `ViewScopeServer/Sources/ViewScopeServer/Snapshot/SnapshotScreenshotRenderer.swift`
- Create: `ViewScopeServer/Sources/ViewScopeServer/Console/SnapshotConsoleTargetBuilder.swift`
- Create: `ViewScopeServer/Sources/ViewScopeServer/Mutation/ViewMutationExecutor.swift`
- Create: `ViewScopeServer/Sources/ViewScopeServer/Support/ViewScopeRuntimeIvarReader.swift`
- Create: `ViewScopeServer/Tests/ViewScopeServerTests/SnapshotTreeBuilderTests.swift`
- Create: `ViewScopeServer/Tests/ViewScopeServerTests/SnapshotDetailBuilderTests.swift`
- Create: `ViewScopeServer/Tests/ViewScopeServerTests/ViewMutationExecutorTests.swift`
- Modify: `ViewScopeServer/Tests/ViewScopeServerTests/ViewScopeServerTests.swift`

- [ ] **Step 1: Write the failing snapshot and mutation tests**

Add focused tests for:

```swift
func testChildCollectorAddsVisibleTableRowsWithoutDuplicates()
func testTreeBuilderOnlyTagsExactControllerRootViews()
func testDetailBuilderUsesWindowContentViewAsScreenshotRootWhenAvailable()
func testMutationExecutorRejectsInvalidColorAndUnsupportedProperty()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path ViewScopeServer --filter SnapshotTreeBuilderTests --filter SnapshotDetailBuilderTests --filter ViewMutationExecutorTests`
Expected: FAIL because the extracted builders and executor do not exist yet.

- [ ] **Step 3: Extract the snapshot pipeline and mutation executor**

Implement focused pieces such as:

```swift
struct SnapshotChildViewCollector {
    @MainActor
    func collectedChildren(of view: NSView) -> [NSView] { ... }
}

enum ViewMutationExecutor {
    @MainActor
    static func apply(_ property: ViewScopeEditableProperty, to reference: ViewScopeInspectableReference) throws { ... }
}
```

Keep Chinese comments in:

- system container child-collection rules
- composite screenshot policy
- top-left canvas coordinate normalization
- mutation safety constraints

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path ViewScopeServer --filter SnapshotTreeBuilderTests --filter SnapshotDetailBuilderTests --filter ViewMutationExecutorTests`
Expected: PASS and `ViewScopeSnapshotBuilder.swift` becomes a thin facade or disappears.

- [ ] **Step 5: Commit**

```bash
git add ViewScopeServer/Sources/ViewScopeServer/ViewScopeSnapshotBuilder.swift ViewScopeServer/Sources/ViewScopeServer/Snapshot ViewScopeServer/Sources/ViewScopeServer/Console/SnapshotConsoleTargetBuilder.swift ViewScopeServer/Sources/ViewScopeServer/Mutation/ViewMutationExecutor.swift ViewScopeServer/Sources/ViewScopeServer/Support/ViewScopeRuntimeIvarReader.swift ViewScopeServer/Tests/ViewScopeServerTests/SnapshotTreeBuilderTests.swift ViewScopeServer/Tests/ViewScopeServerTests/SnapshotDetailBuilderTests.swift ViewScopeServer/Tests/ViewScopeServerTests/ViewMutationExecutorTests.swift ViewScopeServer/Tests/ViewScopeServerTests/ViewScopeServerTests.swift
git commit -m "refactor: split snapshot and mutation pipeline"
```

## Task 8: Remove Remaining Duplication, Add Chinese Comments, And Run Full Verification

**Files:**
- Modify: files touched in Tasks 2-7 as needed after final duplication review
- Test: full client and server suites

- [ ] **Step 1: Write the failing duplication/regression checks**

Add a final small regression test where needed, for example:

```swift
func testWorkspaceConsoleAutoSyncKeepsPreferredTargetAfterCaptureRefresh() async
func testSceneSelectionUpdateDoesNotRebuildWholeStructure() async
```

Only add tests for real regressions discovered during the refactor; do not add placeholder coverage.

- [ ] **Step 2: Run targeted tests to verify the regression exists**

Run the smallest relevant command for each discovered regression before fixing it.
Expected: FAIL or reproduce the issue clearly.

- [ ] **Step 3: Remove duplication and add final Chinese comments**

Review touched files for:

```swift
// 这里用 connection generation 保护异步回调，
// 避免旧会话在 host 切换后把新状态覆盖回去。
```

and:

```swift
// 只有这些系统容器需要补采直接子节点；
// 如果把普通 subviews 再额外拼一遍，会引入重复节点。
```

Consolidate repeated helpers instead of keeping near-identical branches in multiple controllers/builders.

- [ ] **Step 4: Run the full verification suite**

Run:

```bash
xcodebuild -project ViewScope/ViewScope.xcodeproj -scheme ViewScope -destination 'platform=macOS' test
swift test --package-path ViewScopeServer
xcodebuild -project ViewScopeServer/ViewScopeServer.xcodeproj -scheme ViewScopeServer -destination 'generic/platform=macOS' build CODE_SIGNING_ALLOWED=NO
```

Expected:

- `ViewScope` tests PASS
- `ViewScopeServer` package tests PASS
- framework build succeeds without new warnings that indicate missing files or duplicate symbols

- [ ] **Step 5: Commit**

```bash
git add ViewScope/ViewScope ViewScope/ViewScopeTests ViewScopeServer/Sources/ViewScopeServer ViewScopeServer/Tests/ViewScopeServerTests ViewScope/ViewScope.xcodeproj/project.pbxproj ViewScopeServer/ViewScopeServer.xcodeproj/project.pbxproj
git commit -m "refactor: complete architecture responsibility split"
```

## Notes

- Favor moving logic verbatim first, then simplify. Do not rewrite rules and relocate code in the same sub-step unless a failing test proves the rewrite is required.
- If a moved type temporarily keeps its old file path to reduce project churn, that is acceptable as an intermediate state, but the end state should match the functional grouping above.
- When splitting files, keep symbol visibility tight (`private`, `fileprivate`) so internal helper sprawl does not simply reappear under new names.
- `WorkspaceStore` and `ViewScopeInspector` are intentionally preserved as stable facades; do not turn them back into dumping grounds.
