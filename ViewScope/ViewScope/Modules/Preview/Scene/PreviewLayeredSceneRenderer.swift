import AppKit
import SceneKit

enum PreviewLayeredSceneConstants {
    static let unitScale: CGFloat = 0.01
    static let defaultPitch: CGFloat = (-10 * .pi) / 180
    static let defaultYaw: CGFloat = 0.6 // ≈34°
    /// 俯仰角上限：超过 80° 后画面几乎侧对相机，继续旋转没有意义。
    static let maximumPitch: CGFloat = (80 * .pi) / 180
    static let selectableCategoryMask = 1 << 1
    static let minimumZoom: CGFloat = 0.35
    static let maximumZoom: CGFloat = 4
    static let flatDepthStep: CGFloat = 0.01
    /// 层间距（pt）换算成 scene z 步长的系数：步长与间距线性相关，10–150 全区间都有效果。
    static let layerSpacingDepthFactor: CGFloat = 0.005
    static let sameZIndexBiasStep: CGFloat = 0.0001
    static let maskNodeZOffset: CGFloat = 0.001
    static let borderNodeZOffset: CGFloat = 0.002
    static let selectionOverlayZOffset: CGFloat = 0.004
    static let hoverOverlayZOffset: CGFloat = 0.005
    static let diagnosticsOverlayZOffset: CGFloat = 0.003
    /// 覆盖层的渲染顺序，保证永远画在所有平面之后（即最上面）。
    static let overlayRenderingOrder = 10_000_000
    /// zoom=1 时画布内容占视图的比例（0-1），可调整。
    static let defaultFillRatio: CGFloat = 0.7
    static let cameraSensorHeight: CGFloat = 24 // SceneKit 默认 sensorSize.height
    static let cameraDistance: CGFloat = 34
    /// 非精确滚轮（传统鼠标）每一格对应的平移距离（pt）。
    static let lineScrollDistance: CGFloat = 12

    /// 层间距对应的 z 步长。
    static func depthStep(displayMode: WorkspacePreviewDisplayMode, layerSpacing: CGFloat) -> CGFloat {
        guard displayMode == .layered else {
            return flatDepthStep
        }
        return max(layerSpacing, 1) * layerSpacingDepthFactor
    }
}

/// 一个独立显示平面对应的 SceneKit 节点：内容平面 + 选中蒙层 + 边框。
final class PreviewLayeredDisplayNode {
    let node = SCNNode()

    private let contentPlane = SCNPlane(width: 1, height: 1)
    private let contentNode = SCNNode()
    private let maskPlane = SCNPlane(width: 1, height: 1)
    private let maskNode = SCNNode()
    private let borderNode = SCNNode()
    private(set) var item: PreviewLayeredScenePlan.Item?
    /// 当前纹理对应的缓存 key；相同 key 时复用纹理，不重新裁切。
    private(set) var textureKey: String?
    /// 边框外观签名，避免选中变化时为所有节点重建边框几何。
    private var borderSignature: String?

    var zPosition: CGFloat {
        CGFloat(node.position.z)
    }

    init() {
        contentPlane.firstMaterial?.isDoubleSided = true
        contentPlane.firstMaterial?.lightingModel = .constant
        contentPlane.firstMaterial?.diffuse.contents = NSColor.clear
        contentPlane.firstMaterial?.diffuse.wrapS = .clamp
        contentPlane.firstMaterial?.diffuse.wrapT = .clamp
        // 平面之间靠 renderingOrder 由后往前绘制；关闭深度写入，避免透明像素挡住后面的平面。
        contentPlane.firstMaterial?.writesToDepthBuffer = false
        contentNode.geometry = contentPlane
        node.addChildNode(contentNode)

        maskPlane.firstMaterial?.isDoubleSided = true
        maskPlane.firstMaterial?.lightingModel = .constant
        maskPlane.firstMaterial?.diffuse.contents = NSColor.systemBlue
        maskPlane.firstMaterial?.writesToDepthBuffer = false
        maskPlane.firstMaterial?.readsFromDepthBuffer = false
        maskNode.geometry = maskPlane
        maskNode.position.z = PreviewLayeredSceneConstants.maskNodeZOffset
        maskNode.isHidden = true
        node.addChildNode(maskNode)

        borderNode.position.z = PreviewLayeredSceneConstants.borderNodeZOffset
        node.addChildNode(borderNode)
    }

    /// 更新几何与纹理。`textureProvider` 只有在纹理 key 变化时才会被调用。
    func configure(
        item: PreviewLayeredScenePlan.Item,
        textureKey: String,
        canvasSize: CGSize,
        renderingOrder: Int,
        textureProvider: () -> NSImage
    ) {
        self.item = item
        node.name = "display-\(item.nodeID)"
        contentNode.name = item.nodeID
        contentNode.categoryBitMask = PreviewLayeredSceneConstants.selectableCategoryMask
        contentNode.renderingOrder = renderingOrder
        maskNode.renderingOrder = renderingOrder + 1
        borderNode.renderingOrder = renderingOrder + 2

        let rect = item.visibleRect
        let unitScale = PreviewLayeredSceneConstants.unitScale
        let width = max(rect.width * unitScale, 0.001)
        let height = max(rect.height * unitScale, 0.001)
        contentPlane.width = width
        contentPlane.height = height
        maskPlane.width = width
        maskPlane.height = height

        if self.textureKey != textureKey {
            contentPlane.firstMaterial?.diffuse.contents = textureProvider()
            self.textureKey = textureKey
        }

        // 只更新 x/y，z 由 `updateZPosition` 单独维护，避免结构刷新打断层间距动画。
        let z = node.position.z
        node.position = SCNVector3(
            Float((rect.midX - (canvasSize.width / 2)) * unitScale),
            Float(((canvasSize.height / 2) - rect.midY) * unitScale),
            Float(z)
        )
        borderSignature = nil
    }

    func updateZPosition(_ z: CGFloat) {
        var position = node.position
        position.z = z
        node.position = position
    }

    /// 只修改外观（蒙层、边框颜色），不触碰纹理与位置。
    func updateAppearance(isSelected: Bool, isFocused: Bool, showsBorder: Bool) {
        guard let item else {
            return
        }

        if isSelected {
            maskNode.isHidden = false
            maskNode.opacity = 0.35
        } else if isFocused {
            maskNode.isHidden = false
            maskNode.opacity = 0.18
        } else {
            maskNode.isHidden = true
        }

        let showsBorderNode = showsBorder || isSelected || isFocused
        guard showsBorderNode else {
            borderNode.isHidden = true
            return
        }
        let alpha: CGFloat = isSelected ? 1 : (isFocused ? 0.55 : 0.22)
        let signature = "\(item.visibleRect.width)x\(item.visibleRect.height)|\(alpha)"
        borderNode.isHidden = false
        guard borderSignature != signature else {
            return
        }
        borderSignature = signature
        borderNode.geometry = PreviewLayeredSceneSnapshotFactory.makeBorderGeometry(
            size: item.visibleRect.size,
            unitScale: PreviewLayeredSceneConstants.unitScale,
            color: NSColor.systemBlue.withAlphaComponent(alpha)
        )
    }
}

enum PreviewLayeredSceneSnapshotFactory {
    /// 从根截图裁出某个平面的纹理：只保留可见区域，并清掉 punch-out 区域。
    static func makeTextureImage(
        for item: PreviewLayeredScenePlan.Item,
        rootImage: NSImage,
        canvasSize: CGSize,
        pixelScale: CGFloat
    ) -> NSImage {
        let targetRect = item.visibleRect
        guard targetRect.width > 0,
              targetRect.height > 0,
              canvasSize.width > 0,
              canvasSize.height > 0 else {
            return NSImage(size: NSSize(width: 1, height: 1))
        }

        return drawTopLeftImage(size: targetRect.size, pixelScale: pixelScale) { bounds in
            let drawRect = CGRect(
                x: -targetRect.minX,
                y: -targetRect.minY,
                width: canvasSize.width,
                height: canvasSize.height
            )
            rootImage.draw(
                in: drawRect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )
            clearPunchOuts(item.punchedOutRects, origin: targetRect.origin, bounds: bounds)
        }
    }

    /// 使用节点自身的截图（solo / group）作为纹理，只保留可见区域。
    ///
    /// - group 截图包含后代像素，需要 punch-out，避免和后代平面重复；
    /// - solo 截图渲染时已隐藏 sublayer，不含任何其他平面的像素，punch-out 只会在子平面背后挖出空洞，
    ///   因此调用方传 `appliesPunchOuts: false`。
    static func makeTextureImage(
        fromNodeImage image: NSImage,
        item: PreviewLayeredScenePlan.Item,
        pixelScale: CGFloat,
        appliesPunchOuts: Bool = true
    ) -> NSImage {
        let targetRect = item.visibleRect
        guard targetRect.width > 0, targetRect.height > 0 else {
            return NSImage(size: NSSize(width: 1, height: 1))
        }
        return drawTopLeftImage(size: targetRect.size, pixelScale: pixelScale) { bounds in
            // 节点截图覆盖完整 displayRect，按可见区域偏移后绘制。
            let drawRect = CGRect(
                x: item.displayRect.minX - targetRect.minX,
                y: item.displayRect.minY - targetRect.minY,
                width: item.displayRect.width,
                height: item.displayRect.height
            )
            image.draw(
                in: drawRect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )
            if appliesPunchOuts {
                clearPunchOuts(item.punchedOutRects, origin: targetRect.origin, bounds: bounds)
            }
        }
    }

    static func makeTransparentTopLeftImage(size: CGSize) -> NSImage {
        // 透明外壳纹理：只需要一张全透明位图，按 1x 生成即可。
        drawTopLeftImage(size: CGSize(width: max(size.width, 1), height: max(size.height, 1)), pixelScale: 1) { _ in
        }
    }

    /// 把根截图归一成 canvasSize 大小、top-left 方向的工作图，保留原始像素密度。
    static func makeTopLeftWorkingImage(from image: NSImage, size: CGSize) -> NSImage {
        guard size.width > 0,
              size.height > 0 else {
            return image
        }
        let scale = pixelScale(of: image, canvasSize: size)
        return drawTopLeftImage(size: size, pixelScale: scale) { bounds in
            image.draw(
                in: bounds,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )
        }
    }

    /// 源图每 pt 对应的像素数（iOS @3x 截图为 3），限制在 1...3。
    static func pixelScale(of image: NSImage, canvasSize: CGSize) -> CGFloat {
        guard canvasSize.width > 0 else {
            return 1
        }
        let pixelsWide = image.representations
            .map { CGFloat($0.pixelsWide) }
            .filter { $0 > 0 }
            .max() ?? image.size.width
        return min(max((pixelsWide / canvasSize.width).rounded(.up), 1), 3)
    }

    static func makeBorderGeometry(size: CGSize, unitScale: CGFloat, color: NSColor) -> SCNGeometry {
        let halfWidth = Float(size.width * unitScale * 0.5)
        let halfHeight = Float(size.height * unitScale * 0.5)
        let vertices = [
            SCNVector3(-halfWidth, halfHeight, 0),
            SCNVector3(halfWidth, halfHeight, 0),
            SCNVector3(halfWidth, -halfHeight, 0),
            SCNVector3(-halfWidth, -halfHeight, 0)
        ]
        return makeLineGeometry(vertices: vertices, indices: [0, 1, 1, 2, 2, 3, 3, 0], color: color)
    }

    /// 由若干线段组成的几何（每两个顶点一条线段），用于悬停虚线框、诊断描边等覆盖层。
    static func makeSegmentsGeometry(segments: [(SCNVector3, SCNVector3)], color: NSColor) -> SCNGeometry? {
        guard segments.isEmpty == false else {
            return nil
        }
        var vertices: [SCNVector3] = []
        vertices.reserveCapacity(segments.count * 2)
        for segment in segments {
            vertices.append(segment.0)
            vertices.append(segment.1)
        }
        let indices = (0..<UInt32(vertices.count)).map { $0 }
        return makeLineGeometry(vertices: vertices, indices: indices, color: color)
    }

    /// 矩形四条边的线段；`dashLength` > 0 时生成虚线。坐标为 scene 单位。
    static func rectangleSegments(
        center: CGPoint,
        size: CGSize,
        z: CGFloat,
        dashLength: CGFloat = 0
    ) -> [(SCNVector3, SCNVector3)] {
        let minX = center.x - size.width / 2
        let maxX = center.x + size.width / 2
        let minY = center.y - size.height / 2
        let maxY = center.y + size.height / 2
        let corners = [
            CGPoint(x: minX, y: maxY),
            CGPoint(x: maxX, y: maxY),
            CGPoint(x: maxX, y: minY),
            CGPoint(x: minX, y: minY)
        ]
        var segments: [(SCNVector3, SCNVector3)] = []
        for index in 0..<4 {
            let start = corners[index]
            let end = corners[(index + 1) % 4]
            guard dashLength > 0 else {
                segments.append((SCNVector3(start.x, start.y, z), SCNVector3(end.x, end.y, z)))
                continue
            }
            let length = hypot(end.x - start.x, end.y - start.y)
            guard length > 0 else {
                continue
            }
            // 虚线：dash 与 gap 等长，最多 200 段，避免超大矩形生成过多顶点。
            let effectiveDash = max(dashLength, length / 400)
            var offset: CGFloat = 0
            while offset < length {
                let segmentEnd = min(offset + effectiveDash, length)
                let startRatio = offset / length
                let endRatio = segmentEnd / length
                segments.append((
                    SCNVector3(start.x + (end.x - start.x) * startRatio, start.y + (end.y - start.y) * startRatio, z),
                    SCNVector3(start.x + (end.x - start.x) * endRatio, start.y + (end.y - start.y) * endRatio, z)
                ))
                offset += effectiveDash * 2
            }
        }
        return segments
    }

    // MARK: - 私有

    private static func makeLineGeometry<Index: FixedWidthInteger>(
        vertices: [SCNVector3],
        indices: [Index],
        color: NSColor
    ) -> SCNGeometry {
        let source = SCNGeometrySource(vertices: vertices)
        let data = indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let element = SCNGeometryElement(
            data: data,
            primitiveType: .line,
            primitiveCount: indices.count / 2,
            bytesPerIndex: MemoryLayout<Index>.size
        )
        let geometry = SCNGeometry(sources: [source], elements: [element])
        geometry.firstMaterial?.isDoubleSided = true
        geometry.firstMaterial?.lightingModel = .constant
        geometry.firstMaterial?.diffuse.contents = color
        geometry.firstMaterial?.readsFromDepthBuffer = false
        geometry.firstMaterial?.writesToDepthBuffer = false
        return geometry
    }

    /// 在 top-left 方向（flipped）的位图上下文中绘制，位图像素密度为 `pixelScale`。
    private static func drawTopLeftImage(
        size: CGSize,
        pixelScale: CGFloat,
        draw: (CGRect) -> Void
    ) -> NSImage {
        let pixelsWide = max(Int((size.width * pixelScale).rounded(.up)), 1)
        let pixelsHigh = max(Int((size.height * pixelScale).rounded(.up)), 1)
        let bounds = CGRect(origin: .zero, size: size)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ),
        let bitmapContext = NSGraphicsContext(bitmapImageRep: rep) else {
            // 位图创建失败时退回 lockFocus 路径。
            let image = NSImage(size: size)
            image.lockFocusFlipped(true)
            draw(bounds)
            image.unlockFocus()
            return image
        }
        rep.size = size

        // 翻转 CTM，使绘制坐标与数据源一致：原点在左上角、y 向下。
        let cgContext = bitmapContext.cgContext
        cgContext.translateBy(x: 0, y: CGFloat(pixelsHigh))
        cgContext.scaleBy(x: CGFloat(pixelsWide) / size.width, y: -CGFloat(pixelsHigh) / size.height)
        let flippedContext = NSGraphicsContext(cgContext: cgContext, flipped: true)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = flippedContext
        flippedContext.imageInterpolation = .high
        NSColor.clear.setFill()
        bounds.fill(using: .copy)
        draw(bounds)
        flippedContext.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    /// 用 `.copy` 清空 punch-out 区域：多个 punch-out 相互重叠时也不会像 even-odd 裁剪那样“负负得正”。
    private static func clearPunchOuts(_ rects: [CGRect], origin: CGPoint, bounds: CGRect) {
        NSColor.clear.setFill()
        for punchedOutRect in rects {
            let localRect = punchedOutRect
                .offsetBy(dx: -origin.x, dy: -origin.y)
                .intersection(bounds)
            guard localRect.isNull == false, localRect.isEmpty == false else {
                continue
            }
            localRect.fill(using: .copy)
        }
    }
}
