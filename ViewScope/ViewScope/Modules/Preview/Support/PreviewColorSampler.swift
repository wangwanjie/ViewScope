import AppKit

/// 从预览截图中取色（取色器使用）。
///
/// 截图是预览根节点的完整位图，像素尺寸 = 画布尺寸 × 宿主缩放（iOS 可达 3x）。
/// 画布坐标按比例换算成像素坐标后读取；位图按截图对象缓存，避免每次移动鼠标都重新解码。
struct PreviewColorSampler {
    private var cachedImageIdentifier: ObjectIdentifier?
    private var cachedCGImage: CGImage?

    mutating func color(at canvasPoint: CGPoint, in image: NSImage, canvasSize: CGSize) -> NSColor? {
        guard canvasSize.width > 0,
              canvasSize.height > 0,
              let cgImage = cgImage(for: image) else {
            return nil
        }
        guard let pixel = Self.pixelCoordinate(
            for: canvasPoint,
            canvasSize: canvasSize,
            pixelsWide: cgImage.width,
            pixelsHigh: cgImage.height
        ) else {
            return nil
        }
        return Self.srgbColor(of: cgImage, x: pixel.x, y: pixel.y)
    }

    /// 把单个像素绘制进 1x1 的 sRGB 位图后读取：由 CoreGraphics 完成色彩空间转换，
    /// 避免 `NSBitmapImageRep.colorAt` 按 calibrated RGB 解释像素导致的色偏。
    /// CGImage 的像素坐标以左上角为原点，与画布坐标一致。
    static func srgbColor(of cgImage: CGImage, x: Int, y: Int) -> NSColor? {
        guard let pixelImage = cgImage.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }
        var bytes = [UInt8](repeating: 0, count: 4)
        let didDraw = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.setBlendMode(.copy)
            context.draw(pixelImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard didDraw else {
            return nil
        }
        let alpha = CGFloat(bytes[3]) / 255
        // 位图是预乘 alpha，还原成直通颜色。
        func component(_ value: UInt8) -> CGFloat {
            guard alpha > 0 else {
                return 0
            }
            return min(CGFloat(value) / 255 / alpha, 1)
        }
        return NSColor(srgbRed: component(bytes[0]), green: component(bytes[1]), blue: component(bytes[2]), alpha: alpha)
    }

    /// 画布坐标 → 像素坐标；超出范围时返回 nil。
    static func pixelCoordinate(
        for canvasPoint: CGPoint,
        canvasSize: CGSize,
        pixelsWide: Int,
        pixelsHigh: Int
    ) -> (x: Int, y: Int)? {
        guard canvasPoint.x >= 0,
              canvasPoint.y >= 0,
              canvasPoint.x < canvasSize.width,
              canvasPoint.y < canvasSize.height,
              pixelsWide > 0,
              pixelsHigh > 0 else {
            return nil
        }
        let x = Int((canvasPoint.x / canvasSize.width * CGFloat(pixelsWide)).rounded(.down))
        let y = Int((canvasPoint.y / canvasSize.height * CGFloat(pixelsHigh)).rounded(.down))
        return (min(max(x, 0), pixelsWide - 1), min(max(y, 0), pixelsHigh - 1))
    }

    /// `#RRGGBB`，带透明度时为 `#RRGGBBAA`（sRGB）。
    static func hexString(for color: NSColor) -> String {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        func component(_ value: CGFloat) -> Int {
            Int((min(max(value, 0), 1) * 255).rounded())
        }
        let red = component(srgb.redComponent)
        let green = component(srgb.greenComponent)
        let blue = component(srgb.blueComponent)
        let alpha = component(srgb.alphaComponent)
        if alpha >= 255 {
            return String(format: "#%02X%02X%02X", red, green, blue)
        }
        return String(format: "#%02X%02X%02X%02X", red, green, blue, alpha)
    }

    private mutating func cgImage(for image: NSImage) -> CGImage? {
        let identifier = ObjectIdentifier(image)
        if cachedImageIdentifier == identifier, let cachedCGImage {
            return cachedCGImage
        }
        // 选像素最多的表示，保证 iOS @3x 截图按原始分辨率取色。
        var proposedRect = CGRect(origin: .zero, size: image.size)
        let bitmap = image.representations
            .compactMap { $0 as? NSBitmapImageRep }
            .max { $0.pixelsWide < $1.pixelsWide }
        let cgImage = bitmap?.cgImage ?? image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
        cachedImageIdentifier = identifier
        cachedCGImage = cgImage
        return cgImage
    }
}
