#if os(macOS)
import AppKit

/// 把截图编码为 PNG。
@MainActor
struct ViewScopeImageEncoder {
    func pngData(for image: NSImage) -> Data? {
        // 优先直接取 CGImage 构造位图，避免绕道 TIFF 的额外编解码开销（B12）。
        // 像素行序与 TIFF 路径一致（由 `testLayerBacked*Screenshot*` 系列测试覆盖），
        // 窗口合成截图（CGImage 来源）在这条路径下颜色/尺寸也更准确。
        var proposedRect = CGRect(origin: .zero, size: image.size)
        if let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) {
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            bitmap.size = image.size
            return bitmap.representation(using: .png, properties: [:])
        }
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }

    func base64PNG(for image: NSImage) -> String? {
        pngData(for: image)?.base64EncodedString()
    }
}
#endif
