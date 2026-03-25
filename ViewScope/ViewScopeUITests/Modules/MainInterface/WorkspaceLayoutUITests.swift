import XCTest

final class WorkspaceLayoutUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testTreeDividerResizesPreview() throws {
        let app = XCUIApplication()
        app.launchEnvironment["VIEWSCOPE_PREVIEW_FIXTURE"] = "1"
        app.launchEnvironment["VIEWSCOPE_DISABLE_UPDATES"] = "1"
        app.launchEnvironment["VIEWSCOPE_LANGUAGE"] = "en"
        app.launch()

        let mainWindow = app.windows.element(boundBy: 0)
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 10))

        let treePanel = app.descendants(matching: .group)
            .matching(identifier: "workspace.treePanel")
            .firstMatch
        let previewPanel = app.descendants(matching: .group)
            .matching(identifier: "workspace.previewPanel")
            .firstMatch
        XCTAssertTrue(treePanel.waitForExistence(timeout: 5))
        XCTAssertTrue(previewPanel.waitForExistence(timeout: 5))

        let beforeTreeWidth = treePanel.frame.width
        let beforePreviewWidth = previewPanel.frame.width
        let start = treePanel.coordinate(withNormalizedOffset: CGVector(dx: 1.0, dy: 0.5))
            .withOffset(CGVector(dx: 5, dy: 0))
        let end = start.withOffset(CGVector(dx: 120, dy: 0))

        start.press(forDuration: 0.1, thenDragTo: end)

        let afterTreeWidth = treePanel.frame.width
        let afterPreviewWidth = previewPanel.frame.width
        XCTAssertGreaterThan(
            afterTreeWidth,
            beforeTreeWidth + 20,
            """
            Expected dragging the divider to widen the tree panel.
            tree before=\(beforeTreeWidth) after=\(afterTreeWidth)
            preview before=\(beforePreviewWidth) after=\(afterPreviewWidth)
            treeFrame=\(treePanel.frame) previewFrame=\(previewPanel.frame)
            """
        )
        XCTAssertGreaterThan(
            afterPreviewWidth,
            0,
            "Preview panel should remain visible after divider drag."
        )
    }
}
