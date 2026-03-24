import XCTest
@testable import ViewScope

final class WorkspaceModuleSmokeTests: XCTestCase {
    func testPlannedWorkspaceBoundaryTypesCompile() {
        _ = WorkspaceSelectionController.self
        _ = PreviewRenderContextBuilder.self
    }
}
