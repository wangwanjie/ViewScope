# Preview, Host Switching, and Inspector Editing Design

## Summary

This design addresses four user-facing problems in the current workspace:

1. Layered preview mode is slow, memory-heavy, and visually duplicates host content.
2. One visible layer in the 3D preview appears to rotate differently from the rest.
3. Switching hosts from the toolbar leaves the previous host's preview on screen until a manual disconnect/reconnect cycle.
4. Inspector editing is only partially functional even though several rows appear editable.

The implementation will prioritize performance and correctness over preserving the current layered visual effect. The goal is to make the preview stable, make host switching deterministic, and make Inspector editing reliable before adding more visual complexity.

## Goals

- Remove the duplicate-content rendering behavior in layered preview mode.
- Make layered preview responsive enough for normal rotation and navigation.
- Ensure switching hosts immediately clears stale preview/detail state and never paints an old host over a new one.
- Make all currently editable Inspector fields actually commit successfully or fail with a visible rollback.
- Expand editable Inspector coverage with a small set of high-value, low-risk properties.
- Add automated coverage for the new rendering decisions, host-switch lifecycle, and mutation handling.

## Non-Goals

- Preserve the current "every node is textured with a live screenshot slice" effect.
- Redesign the overall workspace layout or toolbar interaction model.
- Add arbitrary AppKit or CALayer mutation support.
- Introduce a new rendering stack such as Metal or SceneKit in this round.

## Current Root Causes

### Layered preview

[`PreviewCanvasView`](/Users/VanJay/Documents/Work/Personal/ViewScope/ViewScope/ViewScope/UI/Workspace/PreviewCanvasView.swift) currently renders layered mode in two separate screenshot-based passes:

- `drawLayeredImage(_:in:context:)` draws a perspective-transformed version of the full screenshot as a base plane.
- `drawLayeredPreview(for:)` then iterates visible nodes and, for each node, crops another screenshot slice and perspective-transforms that slice again.

This means the host UI is rendered once as a full plane and then rendered again in many overlapping node slices. The result matches the observed symptoms: repeated content, expensive Core Image work during rotation, and elevated memory use.

The visually inconsistent layer is most likely the full-image base plane. It is not a separate subsystem, but it appears distinct because it stacks underneath a second pass made of per-node screenshot slices.

### Host switching

[`WorkspaceStore.connect(to:)`](/Users/VanJay/Documents/Work/Personal/ViewScope/ViewScope/ViewScope/Services/WorkspaceStore.swift) creates a new session and starts loading a new host without first clearing old capture state. The store also does not guard against late responses from an older session writing back into the current store state.

### Inspector editing

[`InspectorPanelController`](/Users/VanJay/Documents/Work/Personal/ViewScope/ViewScope/ViewScope/UI/Workspace/InspectorPanelController.swift) already has commit handlers for text, toggle, numeric, and color rows. The app-side editing UI is therefore not missing entirely. The remaining problem is end-to-end reliability:

- some editable rows likely depend on stale node detail or capture context,
- current mutation coverage is narrower than the UI suggests,
- failure paths are not strong enough to guarantee a clean rollback and a trustworthy post-refresh state.

## Design

### 1. Preview rendering model

Layered preview mode will be reduced to a single screenshot plane plus vector overlays:

- Keep one perspective-transformed full screenshot plane for the host snapshot.
- Remove per-node screenshot-slice rendering from `drawLayeredPreview(for:)`.
- Keep layered depth perception by drawing vector outlines, fills, and selection/highlight overlays per node using the existing projected quads.
- Continue using the same `PreviewLayerTransform` projection model for hit testing and drawing.

This preserves the useful 3D hierarchy shape without repeatedly texturing the same host content. The rendering contract becomes:

- `flat`: full screenshot or wireframe fallback.
- `layered`: single full screenshot plane, then vector depth overlays only.

This change also resolves the "one layer rotates differently" complaint because the screenshot content exists in only one transformed layer.

### 2. Preview state reset rules

Preview content will be treated as session-scoped state, not as durable workspace state.

When switching hosts:

- immediately disconnect the old session,
- invalidate the old auto-refresh timer,
- clear `capture`,
- clear `selectedNodeID`,
- clear `selectedNodeDetail`,
- clear `focusedNodeID`,
- clear any preview image derived from the old node detail by virtue of clearing that detail,
- keep user preference state such as zoom level and display mode unless explicitly reset elsewhere.

The preview area should switch to empty/loading state immediately after the host selection changes and remain there until the first successful capture from the new host arrives.

### 3. Connection generation guard

The store will track a monotonically increasing connection generation token. Every async operation launched from a given session will capture that generation and must prove it still matches the current generation before mutating store state.

This applies to:

- `open()`
- `refreshCapture()`
- `requestNodeDetail()`
- `highlight()`
- `applyMutation()`

If an old request finishes after the user has switched hosts, its response is ignored. This prevents stale captures, stale details, and stale mutation refreshes from repainting the workspace with the wrong host.

### 4. Inspector editing behavior

The first requirement is correctness for rows that are already shown as editable. Those controls must either:

- commit successfully to the inspected host and refresh into the new value, or
- fail cleanly, restore the displayed value, and expose an error message.

The app-side commit flow will remain centered in `InspectorPanelController`, but the store and server interaction will be tightened:

- each commit disables the edited control until the mutation round-trip finishes,
- local validation failures still beep and revert immediately,
- remote failures revert the visible field and surface the server error,
- successful mutations trigger a capture refresh and selection normalization without allowing stale responses from prior generations.

### 5. Expanded editable property set

This round will keep a strict whitelist and only add low-risk properties that fit the existing Inspector model types.

New editable targets to add:

- `window.title`
- `view.toolTip`
- `enabled`
- `button.state` for stateful `NSButton` instances only
- `textField.placeholderString`
- `layer.cornerRadius`
- `layer.borderWidth`

Existing editable targets that must remain reliable:

- `hidden`
- `alpha`
- `frame.*`
- `bounds.*`
- `contentInsets.*`
- `backgroundColor`
- `control.value`

The Inspector UI should only render editable controls for properties that the server explicitly marks editable. Unknown or unsupported detail items remain visible as read-only rows.

For property naming, the plan should reuse the existing server key conventions wherever they already exist in detail payloads instead of inventing parallel client-only names.

### 6. Failure handling

#### Host switching

- If a new host fails to connect, the workspace remains empty for that host and shows the error state.
- The app must not restore the previous host's last capture automatically.

#### Mutations

- Invalid client-side values revert immediately before the request is sent.
- Unsupported server-side properties or missing node references return an error and revert the control state.
- If the selected node disappears after a mutation-triggered refresh, selection falls back through the existing normalization path.

## Implementation Boundaries

### Client files

- [`PreviewCanvasView.swift`](/Users/VanJay/Documents/Work/Personal/ViewScope/ViewScope/ViewScope/UI/Workspace/PreviewCanvasView.swift): remove per-node screenshot slicing and simplify layered drawing to one screenshot plane plus vector overlays.
- [`PreviewPanelController.swift`](/Users/VanJay/Documents/Work/Personal/ViewScope/ViewScope/ViewScope/UI/Workspace/PreviewPanelController.swift): keep loading/empty-state transitions correct as capture/detail state resets during host switching.
- [`WorkspaceStore.swift`](/Users/VanJay/Documents/Work/Personal/ViewScope/ViewScope/ViewScope/Services/WorkspaceStore.swift): add the session reset path and generation guard for async responses.
- [`InspectorPanelController.swift`](/Users/VanJay/Documents/Work/Personal/ViewScope/ViewScope/ViewScope/UI/Workspace/InspectorPanelController.swift): keep control disable/re-enable and rollback behavior aligned with the stricter store semantics.
- [`InspectorViewModels.swift`](/Users/VanJay/Documents/Work/Personal/ViewScope/ViewScope/ViewScope/UI/Workspace/InspectorViewModels.swift): surface the newly supported editable properties through existing row types where possible.

### Server files

- [`ViewScopeInspector.swift`](/Users/VanJay/Documents/Work/Personal/ViewScope/ViewScopeServer/Sources/ViewScopeServer/ViewScopeInspector.swift): extend mutation routing and validation for the added property whitelist.
- Snapshot/detail builder files in `ViewScopeServer/Sources/ViewScopeServer/`: emit editable metadata for the newly supported properties so the client only offers controls that the host can mutate.

## Testing Strategy

### Automated tests

- Add preview rendering decision tests to lock in the new "single screenshot plane in layered mode" behavior.
- Add store tests for host switching that assert old capture/detail state is cleared immediately and stale async responses are ignored.
- Extend server mutation tests to cover both current editable fields and the new whitelist additions.
- Extend app-side Inspector tests to verify editable rows are surfaced only when the payload marks them editable.

### Manual verification

Manual verification is still required for:

- 3D preview responsiveness on a real host or fixture,
- toolbar host switching behavior,
- end-to-end Inspector edits on live AppKit controls.

The user has already offered to help execute any UI flows that are difficult to automate. That should be used if local automation is insufficient for trackpad-heavy preview interactions or live-host behavior.

## Rollout Order

1. Fix host-switch state clearing and stale-response protection first, because it affects every later validation step.
2. Simplify layered preview rendering next, because it removes the major performance and visual correctness issue.
3. Repair currently editable Inspector fields end-to-end.
4. Add the new low-risk editable properties.
5. Run focused automated verification, then manual QA with user assistance if needed.
