//
//  ViewScopeUITests.swift
//  ViewScopeUITests
//
//  Created by VanJay on 2026/3/18.
//

import XCTest

final class ViewScopeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testPreviewWorkspaceRendersAndExportsScreenshots() throws {
        let app = XCUIApplication()
        app.launchEnvironment["VIEWSCOPE_PREVIEW_FIXTURE"] = "1"
        app.launchEnvironment["VIEWSCOPE_DISABLE_UPDATES"] = "1"
        app.launchEnvironment["VIEWSCOPE_LANGUAGE"] = "en"
        app.launch()

        let mainWindow = app.windows.element(boundBy: 0)
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Sample Notes"].waitForExistence(timeout: 5))
        writeScreenshot(mainWindow.screenshot(), named: "main-window")

        app.typeKey(",", modifierFlags: .command)
        let preferencesWindow = app.windows["Preferences"]
        XCTAssertTrue(preferencesWindow.waitForExistence(timeout: 5))
        writeScreenshot(preferencesWindow.screenshot(), named: "preferences")

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "ViewScope Preview Workspace"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func writeScreenshot(_ screenshot: XCUIScreenshot, named name: String) {
        let screenshotsDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("READMEAssets", isDirectory: true)

        try? FileManager.default.createDirectory(
            at: screenshotsDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let screenshotURL = screenshotsDirectory.appendingPathComponent("\(name).png")
        try? screenshot.pngRepresentation.write(to: screenshotURL)
    }
}
