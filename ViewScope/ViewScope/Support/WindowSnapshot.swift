import AppKit

enum WindowSnapshotError: LocalizedError {
    case missingWindow
    case missingSnapshotView
    case bitmapCreationFailed
    case pngEncodingFailed

    var errorDescription: String? {
        switch self {
        case .missingWindow:
            return AppLocalization.backgroundString("snapshot.error.missing_window")
        case .missingSnapshotView:
            return AppLocalization.backgroundString("snapshot.error.missing_snapshot_view")
        case .bitmapCreationFailed:
            return AppLocalization.backgroundString("snapshot.error.bitmap_creation_failed")
        case .pngEncodingFailed:
            return AppLocalization.backgroundString("snapshot.error.png_encoding_failed")
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
