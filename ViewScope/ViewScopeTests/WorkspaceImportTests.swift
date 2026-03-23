import AppKit
import Foundation
import Testing
@testable import ViewScope

@Suite(.serialized)
@MainActor
struct WorkspaceImportTests {
    @Test func importedCaptureClearsConsoleTargetsAndCurrentTarget() async throws {
        let sourceStore = try makeFixtureStore()
        defer { sourceStore.shutdown() }
        sourceStore.start()
        try await Task.sleep(nanoseconds: 100_000_000)

        await sourceStore.selectNode(withID: "window-0-view-1-2", highlightInHost: false)
        #expect(sourceStore.consoleCandidateTargets.isEmpty == false)
        #expect(sourceStore.consoleCurrentTarget != nil)

        let export = try #require(sourceStore.makeRawPreviewExport())
        let data = try WorkspaceArchiveCodec.encode(export)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportedConsoleFixture-\(UUID().uuidString)")
            .appendingPathExtension(WorkspaceArchiveCodec.fileExtension)
        try data.write(to: fileURL)
        defer {
            try? FileManager.default.removeItem(at: fileURL)
        }

        let importedStore = try makeDisconnectedStore()
        defer { importedStore.shutdown() }
        try importedStore.loadPreviewExport(from: fileURL)

        #expect(importedStore.connectionState.supportsConsole == false)
        #expect(importedStore.consoleCandidateTargets.isEmpty)
        #expect(importedStore.consoleCurrentTarget == nil)
        #expect(importedStore.consoleRecentTargets.isEmpty)
    }

    private func makeFixtureStore() throws -> WorkspaceStore {
        let defaults = try #require(UserDefaults(suiteName: "WorkspaceImportTests.fixture.\(UUID().uuidString)"))
        let settings = AppSettings(defaults: defaults, environment: ["VIEWSCOPE_PREVIEW_FIXTURE": "1"])
        return try WorkspaceStore(settings: settings)
    }

    private func makeDisconnectedStore() throws -> WorkspaceStore {
        let defaults = try #require(UserDefaults(suiteName: "WorkspaceImportTests.disconnected.\(UUID().uuidString)"))
        let settings = AppSettings(defaults: defaults, environment: [:])
        return try WorkspaceStore(settings: settings)
    }
}
