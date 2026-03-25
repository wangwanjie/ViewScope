import AppKit
import UniformTypeIdentifiers
import ViewScopeServer

@MainActor
final class CaptureFileService {
    private let store: WorkspaceStore

    init(store: WorkspaceStore) {
        self.store = store
    }

    // 统一处理菜单打开、系统 Open With 和导出流程，避免多个入口各自维护文件逻辑。
    func presentOpenPanelAndImportFiles(didImport: @escaping () -> Void, onError: @escaping (Error) -> Void) {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = true
        openPanel.allowedContentTypes = [.viewScopeCapture]

        guard openPanel.runModal() == .OK else { return }
        importFiles(at: openPanel.urls, didImport: didImport, onError: onError)
    }

    func importFiles(at urls: [URL], didImport: @escaping () -> Void, onError: @escaping (Error) -> Void) {
        guard urls.isEmpty == false else { return }

        for url in urls {
            do {
                try store.loadPreviewExport(from: url)
                didImport()
            } catch {
                onError(error)
            }
        }
    }

    func exportCurrentCapture(onError: @escaping (Error) -> Void) {
        guard let document = store.makeRawPreviewExport() else {
            NSSound.beep()
            return
        }

        let savePanel = NSSavePanel()
        savePanel.canCreateDirectories = true
        savePanel.nameFieldStringValue = "ViewScopeCapture-\(document.capture.captureID).\(WorkspaceArchiveCodec.fileExtension)"
        savePanel.allowedContentTypes = [.viewScopeCapture]
        savePanel.isExtensionHidden = false

        guard savePanel.runModal() == .OK,
              let url = savePanel.url else {
            return
        }

        do {
            let data = try WorkspaceArchiveCodec.encode(document)
            try data.write(to: url, options: .atomic)
        } catch {
            onError(error)
        }
    }
}

private extension UTType {
    static let viewScopeCapture = UTType(exportedAs: WorkspaceArchiveCodec.typeIdentifier, conformingTo: .data)
}

