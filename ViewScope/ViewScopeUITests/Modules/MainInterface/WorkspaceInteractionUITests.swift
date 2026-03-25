import XCTest

final class WorkspaceInteractionUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCanvasClickSelectsNode() throws {
        let app = XCUIApplication()
        app.launchEnvironment["VIEWSCOPE_PREVIEW_FIXTURE"] = "1"
        app.launchEnvironment["VIEWSCOPE_DISABLE_UPDATES"] = "1"
        app.launchEnvironment["VIEWSCOPE_LANGUAGE"] = "en"
        app.launch()

        let mainWindow = app.windows.element(boundBy: 0)
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 10))

        let canvas = app.descendants(matching: .group)
            .matching(identifier: "workspace.previewCanvas")
            .firstMatch
        let inspectorPanel = app.descendants(matching: .group)
            .matching(identifier: "workspace.inspectorPanel")
            .firstMatch

        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        XCTAssertTrue(inspectorPanel.waitForExistence(timeout: 5))
        XCTAssertTrue(inspectorPanel.staticTexts["ChartCard"].waitForExistence(timeout: 5))

        let clickPoint = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.102, dy: 0.112))
        clickPoint.click()

        XCTAssertTrue(inspectorPanel.staticTexts["Projects"].waitForExistence(timeout: 5))
    }
}
