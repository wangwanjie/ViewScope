import AppKit

enum WindowSnapshotError: LocalizedError {
    case missingWindow
    case missingSnapshotView
    case bitmapCreationFailed
    case pngEncodingFailed

    var errorDescription: String? {
        switch self {
        case .missingWindow:
            return "The window is not available for snapshot export."
        case .missingSnapshotView:
            return "The window does not have a snapshot-ready content view."
        case .bitmapCreationFailed:
            return "ViewScope could not create a bitmap for the requested snapshot."
        case .pngEncodingFailed:
            return "ViewScope could not encode the snapshot as PNG."
        }
    }
}

enum WindowSnapshot {
    static func writePNG(for window: NSWindow?, to url: URL) throws {
        guard let window else {
            throw WindowSnapshotError.missingWindow
        }
        guard let snapshotView = window.contentView?.superview ?? window.contentView else {
            throw WindowSnapshotError.missingSnapshotView
        }

        snapshotView.layoutSubtreeIfNeeded()
        snapshotView.displayIfNeeded()

        let bounds = snapshotView.bounds.integral
        guard let bitmap = snapshotView.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw WindowSnapshotError.bitmapCreationFailed
        }
        bitmap.size = bounds.size
        snapshotView.cacheDisplay(in: bounds, to: bitmap)

        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw WindowSnapshotError.pngEncodingFailed
        }

        let directoryURL = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try data.write(to: url)
    }
}
