# Workspace Loading And Host Placeholder Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Lookin-style loading progress bar during host switch/manual refresh and stop the host popup from auto-selecting a live host while disconnected.

**Architecture:** Keep loading lifecycle in `WorkspaceStore` so connection and refresh flows expose one source of truth. Render a thin animated progress bar in `PreviewPanelController`, and rebuild `WorkspaceToolbarViewController` so disconnected state uses a placeholder row instead of selecting the first live host.

**Tech Stack:** Swift, AppKit, Combine, SnapKit, Swift Testing

---

### Task 1: Lock The Behavior With Tests

**Files:**
- Modify: `ViewScope/ViewScopeTests/Modules/MainInterface/WorkspaceStoreConnectionLifecycleTests.swift`
- Modify: `ViewScope/ViewScopeTests/ViewScopeTests.swift`

- [ ] **Step 1: Write failing store tests for loading state**
- [ ] **Step 2: Run focused store tests and confirm failure**
- [ ] **Step 3: Write failing toolbar test for disconnected placeholder selection**
- [ ] **Step 4: Run focused UI tests and confirm failure**

### Task 2: Implement Store And UI

**Files:**
- Modify: `ViewScope/ViewScope/Modules/MainInterface/Core/WorkspaceStore.swift`
- Modify: `ViewScope/ViewScope/Modules/MainInterface/Models/WorkspaceModels.swift`
- Modify: `ViewScope/ViewScope/Modules/MainInterface/Controllers/WorkspaceToolbarViewController.swift`
- Modify: `ViewScope/ViewScope/Modules/Preview/Controllers/PreviewPanelController.swift`
- Create: `ViewScope/ViewScope/Modules/MainInterface/Views/WorkspaceLoadingProgressView.swift`
- Modify: `ViewScope/ViewScope/Modules/Preview/Support/PreviewPanelRenderState.swift`
- Modify: `ViewScope/ViewScope/Services/Localization/L10n.swift`
- Modify: `ViewScope/ViewScope/Resources/Internationalization/en.lproj/Localizable.strings`
- Modify: `ViewScope/ViewScope/Resources/Internationalization/zh-Hans.lproj/Localizable.strings`
- Modify: `ViewScope/ViewScope/Resources/Internationalization/zh-Hant.lproj/Localizable.strings`

- [ ] **Step 1: Add published loading state in the store**
- [ ] **Step 2: Drive loading state through connect/refresh success and failure paths**
- [ ] **Step 3: Render and animate the progress bar in preview**
- [ ] **Step 4: Rebuild host popup with a disconnected placeholder item**

### Task 3: Verify

**Files:**
- Test: `ViewScope/ViewScopeTests/Modules/MainInterface/WorkspaceStoreConnectionLifecycleTests.swift`
- Test: `ViewScope/ViewScopeTests/ViewScopeTests.swift`

- [ ] **Step 1: Run focused tests for store lifecycle and toolbar/preview UI**
- [ ] **Step 2: Fix any failures and rerun**
