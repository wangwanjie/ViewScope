# Lookin-Style Hierarchy, Event, 3D Preview, and Console Design

## Summary

This design aligns the current ViewScope hierarchy and preview experience with the specific behavior the user expects from Lookin, while preserving the existing AppKit client architecture and the real host hierarchy model.

The work covers four connected areas:

1. Hierarchy rows must keep the real `NSView` tree but annotate view roots with their owning `NSViewController.view`.
2. Event affordances must behave like Lookin, including left-side handler pills, better icons, and wider popup lists.
3. The 3D preview must switch from per-node perspective stacking to generation-based layered planes with a parallel-view feel and real plane contents.
4. A Lookin-style console helper panel must be added and kept in sync with the current selection.

The current implementation already contains partial work for these areas, but several semantics are still wrong for the approved design. This spec defines the corrected behavior before implementation planning.

## Goals

- Keep the hierarchy tree faithful to the actual AppKit view hierarchy.
- Show controller ownership directly in the row title for root views whose owner satisfies `controller.view === currentView`.
- Preserve system wrapper views in the actual capture, while exposing a convenient UI toggle that filters them from presentation by default.
- Match Lookin-style row affordances for event handlers, including placement, hover, selection colors, and popup behavior.
- Replace the current layered preview depth model with generation-based planes so sibling subviews share the same plane until one of them is expanded.
- Remove the separate bottom screenshot plane and render actual content on each visible plane.
- Replace vanishing-point perspective with a parallel-looking layered transform.
- Add a console helper panel that tracks the current selection and mirrors Lookin’s helper-console interaction model.
- Add focused automated tests for hierarchy metadata, filter behavior, event UI state, layered-plan generation rules, and selection/console synchronization.

## Non-Goals

- Introduce synthetic `NSViewController` nodes into the hierarchy tree.
- Hide actual system wrapper views from the underlying capture model.
- Rebuild the preview using SceneKit in this round.
- Add a general-purpose remote code execution console inside the inspected host.
- Redesign unrelated workspace panels or the app’s top-level navigation.

## Approved Product Decisions

### 1. Hierarchy stays real

- The tree remains a tree of real `NSView` nodes plus window roots.
- System wrapper classes such as `_NSSplitViewItemViewWrapper`, `NSBlurryAlleywayView`, and `_NSSplitViewCollapsedInteractionsView` remain part of the real hierarchy model.
- No synthetic controller nodes are inserted.

### 2. Controller ownership is title metadata, not a separate node

- If a node corresponds exactly to an owning controller’s root view, the row title becomes:
  - `NSView FooViewController.view`
  - `TTKProfileHeaderView TTKProfileHomeViewController.view`
- Descendant views of that controller do not inherit the suffix.
- Controller ownership is therefore explicit on the exact root view node and stays searchable.

### 3. System-wrapper filtering is a presentation toggle

- The client exposes a visible toggle for filtering system wrapper views.
- Default state: enabled, so wrapper views are filtered from the presented hierarchy.
- Toggling the setting triggers a refresh of the current host capture and then rebuilds dependent UI state.
- Filtering is a presentation choice only; it does not alter the underlying capture protocol or server-side traversal.
- If the current selection disappears because filtering is turned on, selection falls back through the existing normalization path.

### 4. Event affordance must match Lookin semantics

- The handler pill sits at the far left of the row.
- It uses a shallow blue rounded rectangle with a fixed corner radius of `5`.
- Hover increases size slightly.
- Selection changes the pill colors so the icon remains readable against the selected row background.
- Clicking the pill opens a transient popup; clicking outside dismisses it.
- The popup is wider than the current implementation and uses a scrollable list layout so long target/action text remains readable.

### 5. 3D depth is generation-based

- Window or focused root content sits on the first plane.
- If a node is collapsed, its descendants do not create additional visible planes.
- If a node is expanded, all of its direct children share the next plane.
- If one of those children is expanded, only that child’s children move to a subsequent plane.
- The result is one plane per visible sibling generation, not one plane per visible node.

### 6. 3D planes show actual content

- The layered preview removes the current “bottom screenshot + overlay quads” model.
- Each visible plane renders the actual content for the nodes assigned to that plane.
- The preview no longer relies on a distinct base screenshot plane under the stack.
- Borders remain optional through the existing layer-border setting.
- Pixel ownership is exclusive by visible generation:
  - a plane keeps the pixels for nodes first assigned to that generation,
  - if an expanded descendant is promoted to a later plane, the ancestor plane punches out that descendant’s visible rect instead of keeping duplicate pixels,
  - later planes render those promoted descendants into the punched-out space.
- Example:
  - if `A` is expanded and `B`/`C` are its direct children, plane `n` shows `A` with the `B` and `C` regions removed, and plane `n + 1` shows `B` and `C`;
  - if `B` is then expanded and exposes `D`/`E`, plane `n + 1` shows `B` with `D`/`E` removed plus `C`, and plane `n + 2` shows `D` and `E`.

### 7. 3D transform uses a parallel-looking view

- The new layered transform must visually read like Lookin’s preview: stacked planes with no vanishing-point convergence.
- Interaction still supports drag/rotate-style adjustment, but the math changes from perspective projection to affine-style parallel stacking.
- Existing hit-testing, focus, and selection must be updated to follow the new plane geometry.

### 8. Console matches Lookin’s helper panel

- The console is a helper panel driven by the current inspected target, not an arbitrary shell or scripting terminal.
- It shows the current target context, history rows, input row, and a clear affordance.
- Its context tracks the current selection, including view and owning-controller metadata when available.
- It reuses the existing transport where possible and stays aligned with current selection/focus flows.

## Current Problems To Correct

### Hierarchy presentation

The current tree work adds controller metadata and icons, but it still treats controller information as secondary presentation. That is insufficient because the approved UX requires the owning controller to appear directly in the title of the exact root view node, while keeping the node itself a plain `NSView`.

### Wrapper visibility

The user does not want wrapper views permanently removed from the actual hierarchy. They only want the default presentation to hide them, with an easy way to turn them back on and refresh immediately.

### Event affordance

The current event pill is close, but its placement, selected-row colors, popup width, and list layout do not yet match the approved behavior.

### Layered preview

The current layered-plan implementation still allocates depth too granularly and is based on a projected-quad model that reads like perspective projection. It also depends on a distinct base image plane that the approved design explicitly removes.

### Console

The current client has no Lookin-style helper console panel tied to selection context.

## Design

### 1. Server metadata contract

The existing server-side hierarchy payload is sufficient as the base contract, but the client will rely on one stricter semantic:

- `rootViewControllerClassName` on a node identifies the owning controller for the exact controller root view.

Implementation planning should verify and tighten the snapshot builder so this value is only emitted for `controller.view === nodeView`, not for arbitrary descendants. Control-action and gesture metadata already exist and should continue to populate `eventHandlers`.

The protocol must also expand in this round:

- bump the wire protocol version from `1` to `2`,
- extend `ViewScopeCapturePayload` with capture-scope preview bitmap assets,
- add console invocation request/response payloads and remote-object references,
- make console object handles explicitly session-scoped and capture-scoped.

### 1.1 Preview asset contract

The layered preview must stop depending on `ViewScopeNodeDetailPayload.screenshotPNGBase64` as its primary image source.

- `ViewScopeCapturePayload` gains one preview bitmap per window root, keyed by the window root node ID.
- Each preview bitmap represents the full `window.contentView` image in the same normalized canvas coordinate space already used by hierarchy node `frame` values.
- Each preview bitmap payload carries:
  - `rootNodeID`,
  - `pngBase64`,
  - `size`,
  - `capturedAt`,
  - an optional `scale` value if the implementation needs pixel-density fidelity.
- The client uses the window-root bitmap for both flat preview and layered preview.
- When a focused subtree is active, the client derives the focused crop and layered masks from that window-root bitmap using hierarchy geometry already present in `ViewScopeCapturePayload`.
- Toggling wrapper filtering only changes visible nodes; it does not require a second preview-bitmap format.
- `ViewScopeNodeDetailPayload.screenshotPNGBase64` may remain temporarily for inspector compatibility, but layered-preview planning should treat capture-scope preview bitmaps as the long-term source of truth.

This contract removes the current dependence on “selected node must already have detail” and gives the planner a stable no-selection path.

### 1.2 Console protocol appendix

The console feature requires new bridge messages and reference models in protocol version `2`.

- Add `ViewScopeRemoteObjectReference`:
  - `captureID`: the capture/reference-context identifier that minted the handle,
  - `objectID`: a host-generated opaque identifier stable only within that capture context,
  - `kind`: `window`, `view`, `viewController`, or `returnedObject`,
  - `className`,
  - `address` when available,
  - `sourceNodeID` when the object is derived from a hierarchy node.
- Add `ViewScopeConsoleTargetDescriptor`:
  - wraps one `ViewScopeRemoteObjectReference`,
  - includes a user-facing title and subtitle for popup rows.
- Extend `ViewScopeNodeDetailPayload` with `consoleTargets` for the currently selected node:
  - for a view node, include the view object target,
  - include the owning view-controller target when the selected node is that controller’s root view,
  - include the window target when it materially helps debugging and the implementation chooses to surface it.
- Add `ViewScopeConsoleInvokeRequestPayload`:
  - `target`: `ViewScopeRemoteObjectReference`,
  - `expression`: the submitted zero-argument selector/property-like text.
- Add `ViewScopeConsoleInvokeResponsePayload`:
  - `submittedExpression`,
  - `target`,
  - `resultDescription`,
  - optional `returnedObject`,
  - optional `errorMessage`.
- Add message kinds:
  - `consoleInvokeRequest`,
  - `consoleInvokeResponse`.

Handle lifetime rules:

- every `captureResponse` carries a new `captureID` that identifies the active reference context,
- any console target or returned object minted under an older `captureID` expires after the next successful capture refresh,
- all handles expire immediately on disconnect,
- if the client sends a stale handle, the host returns a console error instead of crashing or silently succeeding.

### 2. Client hierarchy presentation

The hierarchy row presenter will be adjusted as follows:

- Row title starts with the normalized view class name.
- If the node is an exact controller root view, append ` <ControllerClass>.view`.
- Secondary text keeps ivar traces and other auxiliary metadata.
- Icons remain type-driven and continue to distinguish controller-root views, generic views, labels, buttons, controls, images, tables, outlines, scroll views, and stack views.
- Search indexing continues to include class names, controller names, ivar traces, target/action pairs, gesture metadata, identifiers, and addresses.

Wrapper filtering is applied when building the visible tree model from the capture payload. The filter list is driven by class-name heuristics for known wrapper patterns and stored in app settings so the default-on behavior persists across launches.

### 3. Event pill and popup

The row cell layout changes so the handler pill becomes the leftmost accessory. The pill:

- is hidden when no handlers exist,
- uses a fixed radius instead of a capsule derived from height,
- enlarges slightly on hover,
- swaps to a selected-state palette when the row is selected,
- keeps the icon visible in both selected and unselected states.

The popup controller changes from a simple stacked label sheet to a scrollable list with wider preferred sizing. Each row contains:

- handler icon,
- handler title,
- optional subtitle,
- target/action list,
- gesture enabled/delegate information when available.

The popup remains transient and anchored to the handler pill.

### 4. Generation-based 3D render plan

The layered render plan is rebuilt around visible generations instead of individual node depth indices.

The planner will:

- start from the current root or focused subtree,
- traverse only expanded paths,
- assign each visible sibling generation to one plane index,
- keep all siblings from the same parent generation on the same plane,
- emit one render plane description per plane plus the node contents associated with that plane.

The plan must also preserve enough geometry to support:

- drawing actual plane contents,
- drawing optional borders,
- hit-testing selected nodes,
- focus/selection overlays.

### 5. Plane content rendering

The preview canvas will stop drawing a single base screenshot plane. Instead, it will build plane content from the capture image and node rectangles:

- each plane is rendered from the nodes assigned to it,
- their actual content is composited into that plane’s canvas region,
- the plane is then transformed with the new parallel-stacking transform.

This keeps the visible content aligned with the approved mental model: one plane per visible generation, with the actual host pixels shown on each plane.

### 6. Parallel-style layered transform

The current perspective projection is replaced with an affine-oriented transform that gives a parallel-looking stack:

- no perspective divide,
- no convergence toward a vanishing point,
- z-depth represented by deterministic translation, scale, and shear offsets,
- spacing still controlled by the user-facing layer-spacing slider.

The preview settings continue to expose:

- layer spacing slider,
- show layer borders toggle.

Hit-testing and selection must use the new transformed quads or bounds generated by this transform.

### 7. Console helper panel

The workspace gains a console panel modeled after Lookin’s helper console:

- the panel is opened from the existing workspace context,
- it shows the current target context derived from the selected node,
- it stores lightweight history rows,
- it provides clear-history behavior,
- it updates when selection changes,
- it provides a target-selection popup for highlighted objects and recently returned objects,
- it keeps an auto-sync toggle for “selection drives console target”.

The first implementation round should align the structure and target-synchronization behavior with Lookin without introducing a broader remote execution surface than the app already supports.

### 8. Console interaction contract

The first implementation round follows Lookin’s concrete helper-console model rather than inventing a broader scripting system.

- Console target:
  - the current target is one selectable inspected object,
  - candidate targets come from the current hierarchy selection, prioritizing the actual view object and its owning controller object when available,
  - recently returned objects can also be promoted to the current target,
  - a toggle controls whether the highlighted hierarchy object automatically becomes the console target.
- Supported input:
  - accept a selector or property-like name that can be invoked on the current target,
  - reject method strings containing arguments or dotted-expression syntax in the first round,
  - this keeps the scope aligned with Lookin’s current “invoke zero-argument selector/property name on the target object” behavior.
- Transport and result model:
  - reuse the existing client/server bridge where possible to ask the inspected host to invoke the submitted text on the selected target object,
  - each submission appends a submit row containing target identity plus the submitted text,
  - each successful return appends a return row containing the textual description returned by the host,
  - if the host also returns an object reference, that object is stored in recent-target history and can be selected as a later console target.
- Failure handling:
  - empty input is rejected locally,
  - unsupported syntax is rejected locally with guidance,
  - disconnected-host and remote invocation failures surface as console errors without corrupting history state,
  - clear-history resets the history rows while preserving the input row and current target.

### 9. Console target state rules

The console target must follow one deterministic precedence model.

- If auto-sync is `on`:
  - selection changes replace the current target with the preferred target from the latest selected node detail,
  - the default preferred target is the selected view object,
  - if the selected node is an exact controller root view, the owning controller target is exposed as an alternate target but does not replace the view target automatically.
- If the user manually chooses a recent object or alternate target while auto-sync is `on`, auto-sync is immediately turned `off`, matching Lookin’s behavior.
- If auto-sync is `off`:
  - hierarchy selection changes update the available candidate list,
  - but they do not overwrite the current target.
- On capture refresh:
  - if the current target handle belongs to an older `captureID`, it becomes invalid,
  - if auto-sync is `on`, the client retargets to the latest selected node’s preferred target when available,
  - otherwise the current target is cleared and the input becomes disabled until the user chooses a valid target.
- If filtering or selection normalization removes the previously selected node:
  - auto-sync `on`: retarget to the normalized selection if it exists,
  - auto-sync `off`: retain the current target only if its handle is still valid for the latest `captureID`; otherwise clear it.
- On disconnect:
  - clear the current target,
  - clear selectable recent-object handles,
  - keep textual history rows visible until the user clears them, but disable further submission.

## Implementation Boundaries

### Client files

- [`ViewTreePanelController.swift`](/Users/VanJay/Documents/Work/Private/ViewScope/ViewScope/ViewScope/UI/Workspace/ViewTreePanelController.swift): title formatting, wrapper filter toggle, event pill placement, selected-state styling, popup layout.
- [`WorkspaceStore.swift`](/Users/VanJay/Documents/Work/Private/ViewScope/ViewScope/ViewScope/Services/WorkspaceStore.swift): filter setting persistence, refresh trigger, selection normalization, console synchronization.
- [`PreviewLayeredRenderPlan.swift`](/Users/VanJay/Documents/Work/Private/ViewScope/ViewScope/ViewScope/Support/PreviewLayeredRenderPlan.swift): generation-based plane planning.
- [`PreviewLayerTransform.swift`](/Users/VanJay/Documents/Work/Private/ViewScope/ViewScope/ViewScope/Support/PreviewLayerTransform.swift): parallel-style transform math.
- [`PreviewCanvasView.swift`](/Users/VanJay/Documents/Work/Private/ViewScope/ViewScope/ViewScope/UI/Workspace/PreviewCanvasView.swift): actual plane rendering, border toggle handling, hit-testing updates.
- [`PreviewPanelController.swift`](/Users/VanJay/Documents/Work/Private/ViewScope/ViewScope/ViewScope/UI/Workspace/PreviewPanelController.swift): plane-setting UI integration and console entry point if needed.
- Console-related workspace UI files in `ViewScope/ViewScope/UI/Workspace/`: helper panel model and view controllers.
- Localization files: new strings for wrapper filter and console UI.

### Server files

- [`ViewScopeSnapshotBuilder.swift`](/Users/VanJay/Documents/Work/Private/ViewScope/ViewScopeServer/Sources/ViewScopeServer/ViewScopeSnapshotBuilder.swift): tighten exact controller-root tagging semantics, add capture-scope preview bitmaps, mint capture-scoped console targets, and preserve action/gesture metadata.
- [`ViewScopeBridge.swift`](/Users/VanJay/Documents/Work/Private/ViewScope/ViewScopeServer/Sources/ViewScopeServer/ViewScopeBridge.swift): define protocol version `2`, preview-bitmap payloads, console request/response payloads, and remote-object references.
- [`ViewScopeInspector.swift`](/Users/VanJay/Documents/Work/Private/ViewScope/ViewScopeServer/Sources/ViewScopeServer/ViewScopeInspector.swift): route console invocation requests and stale-handle failures.

## Testing Strategy

### Automated tests

- Add client tests that assert controller-root rows render `Class Controller.view` and descendants do not.
- Add tests for wrapper filtering defaults, visible-tree filtering, and selection fallback when the filter hides the current node.
- Add tests for event-handler search indexing and selected-state row presentation decisions where feasible.
- Rewrite layered-plan tests to assert generation-based plane indices rather than per-node incremental depth.
- Add transform tests that verify the new layered geometry is affine-style and does not rely on perspective division.
- Add console model tests for current-target synchronization and history behavior.
- Keep or extend server tests that verify controller-root tagging, control actions, gestures, and ivar tracing.

### Manual verification

Manual verification is still required for:

- hierarchy rows with controller-root suffixes on real AppKit hosts,
- wrapper-filter toggle behavior and refresh,
- selected-row event pill contrast,
- popup readability with many handlers,
- layered preview interactions and visual parity with the approved semantics,
- console targeting and history behavior on a live inspected host.

## Rollout Order

1. Tighten controller-root metadata semantics and add/adjust tests.
2. Finish hierarchy title rendering, wrapper filtering, icons, and event popup behavior.
3. Rebuild the layered render plan around visible generations.
4. Replace the transform and layered canvas rendering with plane-content rendering.
5. Add the console helper panel and selection synchronization.
6. Run focused automated verification, then manual QA against a real host.
